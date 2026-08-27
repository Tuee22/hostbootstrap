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
an unhealthy one is deleted before recreation. Kind creation carries a finite ten-minute driver readiness
bound, followed by a fresh API and declared-node readiness observation. The bound covers a cold Apple/Lima
control plane without turning a failed creation into an unbounded wait. Nvkind adds the NVIDIA runtime smoke,
a control-plane/GPU-worker topology, per-node CPU/memory cordons, and a device-plugin/allocatable-GPU gate.
The strong backend passes the finalized driver into its creation transaction: Kind receives `--config`, while
nvkind receives `--config-template` and performs its NVIDIA containerd/RuntimeClass post-setup. Listing,
kubeconfig readback, identity binding, and conditional deletion use Kind after either creator. Kind's quiet
creation report remains strictly framed. Nvkind has no quiet mode and emits successful progress on both streams,
so only that closed creation branch classifies its process outcome; it then derives authority from fresh
kubeconfig readback and every declared node-container identity, never from the progress text. The accelerator
gate runs before the cluster package is registered, so downstream workloads cannot confuse Ready nodes with
accelerator readiness; the plugin and GPU workload both select nvkind's verified `nvidia` RuntimeClass.

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

`HostBootstrap.Cluster.Backend` supplies the IO that feeds it, and it is now a **join** rather than a
driver. The four
[ownership invariant](../architecture/ownership_invariant.md) clauses are held by
`HostBootstrap.Cluster.Ownership` over the one seam, every effect is a described command interpreted by the
one interpreter, and every decision above it is a total function of the bytes a tool wrote. What is left
here is turning a prepared plan-owned package into the object that driver is about — the cluster's name,
its declared node containers control plane first, the configuration snapshot where the plan declares one,
the durable destination where this run publishes the credential, and this run's durable ownership binding — and turning the
driver's answer into the observation the reconciler classifies.

Kind creation writes its initial kubeconfig to a unique private file opened under the executing platform's
local temporary directory. That keeps Kind's client-side sidecar lock off host-provider mounts such as the
Lima/virtiofs project share. The file exists only for the child invocation and is removed on every exit. Once
Kind accepts creation, the ownership transaction asks Kind for the exact live kubeconfig, validates the bounded
report, flushes it to a private sibling of the plan-owned durable destination, and atomically renames it into
place. Only then may node identities be bound. The same readback-and-publication step precedes binding when a
later entry recovers `ClusterCreatedUnbound`, so interruption or a durable publication failure leaves a
convergent unbound row rather than a bound cluster without its credential.

There is no interpreter, no locking front end, and no injected executor. The private component the executor
lived in is gone, and a source guard holds the absence: it fires on a reintroduced `Python3`, `Flock`,
`Lockf`, `ClusterExec`, or `-c`, and it also asserts that the boundary still reaches the described commands
and the clause-holding driver, so a backend that had stopped driving anything at all would fail rather than
pass quietly. [rationale.md](../../DEVELOPMENT_PLAN/rationale.md) says why a program carried in a string is
refused.

A backend is a value the declaration decides. `discoverStrongClusterBackend` takes the typed
`HostConfig` (§ K), admits it only when all three tools the cluster drives are resolved in it, and probes
nothing: what a discovery once proved — that a writable state directory, a locking front end, and an
interpreter exist — is the protected store's own to establish when the first transaction enters it. A tool
the configuration does not carry is `Unsupported`, so a backend that cannot reach its driver mints no
capability rather than failing at the first effect. The constructor is not exported, so a caller cannot
mint one from chosen tool paths.

The four calls are one transaction shape with four continuations, so the store is opened once per
transaction and the exclusive entry covers the whole of it:

- **reconcile** answers `Created`, `Healthy`, `Unhealthy`, or `Foreign`. A cluster this record already owned
  is asked one further question the creation path does not need — whether every node container the record
  bound is still running — because that is the container runtime's answer rather than the API server's, and
  an owned cluster whose containers are stopped is a conflict an operator resolves rather than something to
  recreate. Something standing at the name under no durable record of this project's is `Foreign` and is
  never adopted.
- **cordon** applies the one budget renderer's wall to each bound container identity and reports a container
  that took a node's name as a replacement.
- **readiness** is read-only and versioned: the counter advances only when this call freshly observed the
  managed identity with the API server and every declared node reporting ready, so a stale observation
  cannot be presented as a fresh one. A container that took a node's name is reported as *that* identity
  rather than as a probe failure, which is what lets settlement tell a replacement apart from a retry.
- **cleanup** re-observes every owned node, removes the cluster through the one interpreter, and forgets a
  record only over a reported absence, leaving a same-named replacement standing.

What a configuration drift changes is upstream of the backend: the ownership identity is derived from the
plan's own stable snapshot digest, of which the rendered cluster configuration is part, so a plan whose
configuration changed presents a different identity, mints a different claim, and finds a record it does not
recognize.

The read-only status path is outside every clause because it mutates nothing: one described command through
the one interpreter and one projection of the cluster report vocabulary's own total classification. Its
refusals stay exactly as narrow — a command that produced no child, a non-zero exit, anything on standard
error, a body that does not end in exactly one newline, a carriage return, a byte outside ASCII, an empty
row, a name outside the portable alphabet, and a repeated name are each the driver contradicting itself, and
each is a refusal rather than an absence, because an absence authorizes creation and a refusal must not.

The exact package layer is unchanged above it. Preparation accepts only a backend-minted Running-provider
dependency and reruns that backend's real probe before offering the cluster call. Production config bytes
are bound by SHA-256 with the exact retained budget in the prepared call; Harness has no config and emits no
`--config`. Only successful cordon plus a fresh real API/all-node Ready reprobe of the exact owner/container
identity can mint `ClusterReadiness`; a replacement identity is a `Conflict`, and the successful
phase-observation counter fails rather than wrapping at exhaustion. Constructors for raw backend results,
managed/cordon/readiness/cleanup authority, and the running dependency remain hidden and nominally indexed.

Chart reconciliation uses Helm's `--rollback-on-failure` contract together with an explicit `--wait` boundary.
The captured-command classifier still requires an empty standard-error stream on success; avoiding Helm's
deprecated `--atomic` spelling keeps the supported rollback behavior without treating a warning as a settled
workload result. On Helm 4, a first install settles only when the exact install announcement is accompanied by
the matching release name, `deployed` status, revision 1, and `Install complete` description; an incomplete or
otherwise unfamiliar zero-exit result remains a failure.

Alongside it, `HostBootstrap.Cluster.Backend` owns automatic local exposure. A plan supplies only
semantic service identity, protocol, and the stable cluster-internal target. After readiness the backend starts
an identity-bound relay on the cluster container network and asks the container runtime to publish each relay
listener on `127.0.0.1` without a host-side number. Runtime creation is therefore both selection and binding;
there is no scan-then-bind window.

Only inspection of the exact relay/container identity may mint `ResolvedExposure`. It binds the selected port
to the plan, cluster generation, service, internal target, and ownership operation, and it travels through the
matching cluster dependency package rather than Dhall or canonical cluster YAML. Recovery re-inspects the
mapping, while release removes the relay by identity before deleting the cluster. Wildcard, missing,
additional, duplicate, changed-target, or replacement mappings are `Conflict`.

The caller-selected `LoopbackExposure` preparation and equality settlement are absent. Public preparation
accepts an applied cluster cordon, an immutable relay image identity, and semantic targets only. The protected
record is published before runtime creation with a fresh 256-bit operation nonce; managed replacement binds
the inspected relay identity and complete mapping set. Cluster cleanup refuses while that record exists, so
release must remove and re-observe the exact relay before cluster deletion can begin. The
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
closed this boundary with the complete warning-clean static gate and a live concurrent-allocation run on
2026-08-22.

A parent-frame consumer does not retain the child's cluster runtime package after the deployment child exits.
For that case, `observeRecordedClusterExposure` opens the exact protected `<cluster>.exposure` row read-only,
admits only a canonical managed record with one requested service, and re-inspects the recorded Docker relay's
name, immutable identity, operation, specification, and complete loopback mapping set before returning the
selected port. `HostBootstrap.Cluster.Shipped` carries that observation through the existing frame-child
transaction into the provider frame that owns Docker. Its bounded response is only the freshly observed port;
no cluster handle, ownership witness, credential, or executable selector crosses back.

What remains is legacy wiring. `ensureCluster` still treats any healthy cluster with `clusterName plan` as
the desired cluster without checking a receipt, and still deletes and recreates an unhealthy same-name
cluster; `clusterDown`/`clusterDelete` still issue `kind delete cluster --name <name>` without proving
this plan created or adopted the resource. Replacing those call sites belongs to the recursive-plan
tranche, not to the backend.

### The cluster as a row of the frame table

Beside that backend the cluster now also exists as a **row** rather than as a module of parallel logic,
and the four modules it is written in are the whole of it. `HostBootstrap.Cluster.Command` says what to
ask — the tool the frame table names, the exact argument vector, the stdio disposition, and the frame
whose process reads it — and declares the three tools a cluster drives in one place, so a driver and the
row that holds its clauses are declared together. `HostBootstrap.Cluster.Report` says what an answer
means, as total classifications over the interpreter's own outcome. `HostBootstrap.Cluster.Resume` says
where an interrupted transaction stands, as a total function of the durable record and the two
authorities' answers. `HostBootstrap.Cluster.Ownership` composes them and holds the four clauses through
the one seam. Nothing in that path is a program written in another language and parsed back.

The object is the cluster **and every node**, because clause 3 binds exactly one identity per record: the
cluster's own record binds the control-plane container and each other node carries its own record beside
it. Every record is published over an explicit absence before the single `kind create cluster`, since one
creation brings every node container into existence at once, and each is bound afterwards from what the
container runtime reports. The node observation asks the node's *name* of the listing and again of the
inspection, so a container replaced between the two answers differently rather than merely re-resolving.

Four transactions run over that object:

- **Reconcile** answers with three end states an operator can tell apart — a first creation, a resumed
  entry whose cluster already existed under this record, and an entry that found every clause held. The
  already-owned path still re-observes every worker, because the cluster's own identity says nothing about
  the other nodes.
- **Readiness** re-enters from the durable records, asks the API server through the kubeconfig the driver
  hands back — over standard input, so no credential is in an argument vector — and answers `ClusterReady`,
  `ClusterApiUnready`, `ClusterNodesUnready`, or `ClusterNodesUndeclared`. None of the four is a fault: a
  control plane that has not come up is exactly what a readiness poll expects to see. The records are
  re-entered on both sides, so a node replaced while the probe ran is a conflict rather than a readiness.
- **Cordon** applies the one budget renderer's wall to the container identity each durable record bound,
  never to the node's name, and re-observes every node on both sides of the application.
- **Release** re-observes every owned node, removes the cluster through the one interpreter, and forgets a
  record only over a reported absence. A container that took a node's name during the removal is left
  standing and no record is forgotten over it, because clause 4 compares the identity rather than the name.
  A record published over a create that never happened is forgotten without any command being issued, since
  clause 2 is the only clause that was ever held.

Its durability is the protected store's compare-and-swap; this boundary holds no durable byte of its own.
The suite drives it with a cluster driver, container runtime, and API server that are **one real process** —
the suite's own executable, entered by an environment variable held for exactly the span of a fixture — so
the clause-holding effects run against a real store and a real client rather than against a substitution
point, and the family runs and is counted on every gate host.

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
nested cluster. On the direct Linux GPU path, the demo hook recovers the exact Docker-visible durable profile
bind and invokes a fixed internal entry in the project image. That entry runs the core retained-cluster
transaction: it re-observes the bound node identities, deletes through the pinned Kind client, proves absence,
and only then releases their protected ownership records. The outer frame separately proves every declared
node absent. These remain project-specific cleanup strategies, not recursive descent/ascent.

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

The recursive reverse command admits the core-managed cluster action through the same durable preparation
boundary as every other frame node. `Cluster.Reconcile.runExactClusterCleanupKernel` requires the exact
admitted plan digest, the prepared operation key, and a `LocalWork` whose plan-derived action is
`DeleteCluster`. The sealed root lifecycle entry is the only caller that can disclose the matching plan and
closed verb: Down selects the retained/down cleanup operation and Destroy selects deletion, with no Boolean
or textual policy input. An exception becomes the ordinary typed failed teardown observation, so the shared
reverse driver can settle or continue siblings without a second cluster-specific control path. The driver
adoption itself is owned by recursive-lifecycle Sprint 17.48.

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
