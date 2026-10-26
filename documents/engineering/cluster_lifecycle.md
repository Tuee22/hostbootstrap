# Cluster Lifecycle

**Status**: Authoritative source
**Supersedes**: the claims that readiness gating is universal and that demo tests use the Test profile
**Referenced by**: [documents index](../README.md), [resource budgeting](resource_budgeting.md), [durable state](../architecture/durable_state.md), [readiness](../architecture/readiness.md), [testing](testing.md)

> **Purpose**: Describe the implemented kind/nvkind/Helm lifecycle and clearly separate its current
> guarantees from the typed lifecycle target.

## TL;DR

`project up` creates, cordons, and readies a cluster through the plan-owned ownership backend
(`discoverStrongClusterBackend`), which never adopts a foreign cluster and never auto-deletes an unhealthy
one. `project down` and `project destroy` release it through the recursive reverse command: the frame that
owns the `deploy-kind` step releases the recorded exposure relay and then the cluster, by bound container
identity, for both verbs. The name-only compatibility actions (`ensureCluster`, `clusterDelete`) remain only
behind the bare `cluster-live` gate. The cluster-node cap is the whole cluster slice on every node; see
[resource budgeting](resource_budgeting.md#what-runs-today).

The cluster modules divide the work as follows:

| Module | Owns |
|---|---|
| `HostBootstrap.Cluster.Lifecycle` | plan types (`ClusterPlan`, `PlanOwnedClusterConfig`, `AcceleratorIngressPlan`), the teardown partition, and the compatibility actions |
| `HostBootstrap.Cluster.Backend` | the strong backend: discovery, prepared calls, exposure relay, and retained release |
| `HostBootstrap.Cluster.Reconcile` | the total reconcile classification and the plan-indexed cluster authorities |
| `HostBootstrap.Cluster.Command`, `HostBootstrap.Cluster.Report`, `HostBootstrap.Cluster.Resume`, `HostBootstrap.Cluster.Ownership` | the described commands, their classifiers, resumption decisions, and the clause-holding transactions |
| `HostBootstrap.Cluster.Shipped` | carrying a recorded exposure observation across a frame boundary |
| `HostBootstrap.Cluster.Budget` | plan-indexed budget admission |
| `HostBootstrap.Cluster.Workload` | the prepared chart workload over a ready cluster |

## Current Status

The gaps between the tree and this page's contract are listed under [Current gaps](#current-gaps). An
unqualified "frame" on this page is the topology sense of the [glossary](../README.md#glossary): a root,
child, or provider frame is a place in the composed topology.

Project chain steps invoke the cluster actions; the plan-owned path runs through
`HostBootstrap.Cluster.Backend` and `HostBootstrap.Cluster.Ownership`. The demo's workload segment is:

```text
deploy-kind or nvkind
  -> deploy-object-store
  -> deploy-registry
  -> push-image
  -> deploy-chart
  -> expose-port
  -> accelerator-daemon placement where selected
```

`deploy-object-store` is required before the registry because the registry uses its bucket as the S3
backend. Linux CPU/GPU append an in-cluster accelerator-daemon deployment; Apple Silicon and Windows GPU
start a host daemon after the web and private daemon ingress are reachable.

`push-image` consumes a `ReadyBlobRoute`, which `settleBlobRoute` mints from a blob `HEAD` observation
against the finalized registry plan, so an image push cannot begin while the registry redirects the host
client to the cluster-only S3 store; see [network reachability](../architecture/network_reachability.md).

Cluster creation is fail-closed around command exit status. The plan-owned backend never auto-deletes an
existing cluster: an unhealthy owned cluster is a conflict (see [The ownership backend](#the-ownership-backend)).
Only the compatibility `ensureCluster` path, reached solely from the bare `cluster-live` gate through
`clusterCreate`, health-probes an existing named cluster and deletes an unhealthy one before recreation; that
gate first refuses any existing same-named cluster. Kind creation carries a finite ten-minute driver readiness
bound, followed by a fresh API and declared-node readiness observation. The bound covers a cold Apple/Lima
control plane without turning a failed creation into an unbounded wait. Nvkind adds the NVIDIA runtime smoke,
a control-plane/GPU-worker topology whose node containers each receive the cluster cordon (see
[Resource limits](#resource-limits)), and a device-plugin/allocatable-GPU gate.
The strong backend passes the finalized driver into its creation transaction: Kind receives `--config`, while
nvkind receives `--config-template` and performs its NVIDIA containerd/RuntimeClass post-setup.

**Which template a cluster is created from is the project's decision, not this library's.** A resolved
plan names none, and a creation that names none passes no config flag at all, taking the driver's own
default topology. The templates are files in a project's own source root, and the choice between them
turns on where that project places its accelerator daemon rather than on the driver, so a library
answer would be a guess that fails closed on every project whose root does not carry that exact
filename. A project that ships templates names one on the plan it hands the backend, and owes a case
that each answer it can give resolves.

**Accelerator ingress is a closed sum with one case per service type.** `AcceleratorIngressPlan` has two
constructors: `ClusterIpIngress` for an in-cluster daemon, carrying only its service port, and
`NodePortIngress` for a host-resident daemon, carrying the service port, the internal node port, and a fixed
`127.0.0.1` listen address. The listen address is retained plan data, not a kind port mapping: the canonical
cluster configuration refuses `hostPort` and `extraPortMappings`, so a cluster publishes no host port, and the
host reaches cluster services through the runtime exposure relay described under
[The ownership backend](#the-ownership-backend). A `ClusterIP` carrying a node port and a `NodePort` carrying
none have no constructor, so the correlation is held by the type rather than by prose
([§ HH](../../DEVELOPMENT_PLAN/development_plan_standards.md#hh-unrepresentable-illegal-state)). A resolved
plan also retains exactly one derived state directory rather than a list that
could be empty, so reading it is total. Listing,
kubeconfig readback, identity binding, and conditional deletion use Kind after either creator. Kind's quiet
creation report remains strictly framed. Nvkind has no quiet mode and emits successful progress on both streams,
so only that closed creation branch classifies its process outcome; it then derives authority from fresh
kubeconfig readback and every declared node-container identity, never from the progress text. The accelerator
gate runs before the cluster package is registered, so downstream workloads cannot confuse Ready nodes with
accelerator readiness; the plugin and GPU workload both select nvkind's verified `nvidia` RuntimeClass.

The [cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
has an independent live linux-cpu gate, reached as a case behind the fixed `test` verb:
`hostbootstrap test run cluster-live`. It creates a fresh kind cluster, waits for node readiness, performs a
read-only node-status query, deletes the cluster and verifies its labelled node containers are absent, then
re-reads a durable-root sentinel outside the deletion boundary. The case drives the compatibility
`clusterCreate`/`clusterDelete` actions, not the plan-owned ownership backend, so it is live evidence for
creation, readiness, name-addressed deletion, and durable-root survival, and not for ownership records,
identity binding, or conditional release. Each of its commands runs through `runTool` with no per-command
deadline. The target routes the case through the plan-owned backend — reconcile, the applied cordon,
readiness, and `releaseRetainedCluster` as the reverse — with every command under a bounded cluster
interpreter (see [Current gaps](#current-gaps)). The exclusive run, the lease, the run-ownership cleanup, and the
report card come from the harness rather than from anything the case arranges itself. The case does not
invoke the demo; demo lifecycle integration and end-to-end durable readback are evidenced by the
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), not by this gate.

The exact prepared cluster adapter produces plan/resource-indexed readiness and ownership settlement.
Convenience `IO ()` waits are descriptive and cannot mint those authorities. See
[readiness](../architecture/readiness.md) and the [lifecycle state model](../architecture/lifecycle_state_model.md).

## Current reconciliation semantics

Managed reconciliation retains the exact handle, receipt, operation fence, and changed/no-op observation.
Foreign, conflicting, and unsupported state remain disjoint from managed success. Convenience actions that
only return `IO ()` claim completion rather than typed idempotence.

### The ownership backend

The typed exact consumer and clause-holding backend are implemented. The demo's cluster step reaches it
through `discoverStrongClusterBackend`, and the root and child reverses release through
`releaseRetainedCluster` (see [Current teardown](#current-teardown)).

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

`HostBootstrap.Cluster.Backend` supplies the IO that feeds it, and it is a **join** rather than a
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
`HostConfig` ([§ K](../../DEVELOPMENT_PLAN/development_plan_standards.md#k-host-tool-resolution-doctrine)),
admits it only when four tools are resolved in it — the plan's creation driver (`Kind` or `Nvkind`),
`Docker`, `Kubectl`, and `Helm` — and probes nothing: that a writable state directory and a locking front end
exist is the protected store's own to establish when the first transaction enters it. A required tool the
configuration does not carry is `Unsupported`, so the backend mints no capability. Listing, kubeconfig
readback, and deletion always run through `Kind`, which discovery does not require on an nvkind plan, so an
nvkind plan without a resolved `Kind` fails at its first such effect rather than at discovery (see
[Current gaps](#current-gaps)). The constructor is not exported, so a caller cannot mint one from chosen tool
paths.

The four `HostBootstrap.Cluster.Backend` calls below are one transaction shape with four continuations, so the
store is opened once per transaction and the exclusive entry covers the whole of it. Their results are the
descriptive call results the prepared reconcile, cordon, readiness, and cleanup calls return; the
`HostBootstrap.Cluster.Ownership` transactions under
[The cluster as a row of the frame table](#the-cluster-as-a-row-of-the-frame-table) run beneath them. A
`ClusterCreated` or `ClusterRecovered` ownership outcome surfaces as `ClusterResultCreated`; a
`ClusterAlreadyOwned` outcome surfaces as `ClusterResultHealthy` when every bound node container is running and
as `ClusterResultUnhealthy` otherwise; and a `ClusterReleased` or `ClusterAlreadyReleased` release outcome
surfaces as `ClusterCleanupRemoved`. The prepared cleanup call has no production caller: production release
runs `releaseRetainedCluster` over the same ownership release (see [Current teardown](#current-teardown)).

- **reconcile** answers `ClusterResultCreated`, `ClusterResultHealthy`, `ClusterResultUnhealthy`, or
  `ClusterResultForeign` — the `ClusterReconcileResultView` cases, whose remaining constructor
  `ClusterResultProbeFailed` reports a probe that could not answer at all. A cluster this record already owned
  is asked one further question the creation path does not need — whether every node container the record
  bound is still running — because that is the container runtime's answer rather than the API server's, and
  an owned cluster whose containers are stopped is a conflict an operator resolves rather than something to
  recreate. Something standing at the name under no durable record of this project's is `Foreign` and is
  never adopted.
- **cordon** applies the one budget renderer's wall to each bound container identity and reports a container
  that took a node's name as a replacement. The wall is the whole cluster slice on every node rather than a
  per-node share (see [Resource limits](#resource-limits)).
- **readiness** is read-only and versioned: the counter advances only on a ready answer — the API server and
  every declared node reporting ready — whose stamped identity equals the managed handle's. A ready answer is
  stamped with the handle's own identity rather than the identity the transaction re-observed, so that
  comparison holds by construction, and a cluster released and recreated under a fresh record between the
  cordon and this call is reported ready under the old identity (see [Current gaps](#current-gaps)). A
  container that took a node's name inside the transaction is reported as *that* identity rather than as a
  probe failure, which is what lets settlement tell a replacement apart from a retry.
- **cleanup** re-observes every owned node, removes the cluster through the one interpreter, and forgets a
  record only over a reported absence, leaving a same-named replacement standing.

What a configuration drift changes is upstream of the backend: the ownership identity is derived from the
plan's own stable snapshot digest, of which the rendered cluster configuration is part, so a plan whose
configuration changed presents a different identity and mints a different claim. The records are keyed by
cluster and node name, and the standing decision (`clusterStanding`, `nodeStanding`) does not compare a
record's claim with the plan's, so that plan treats the previous generation's records as its own and
re-cordons the cluster they bound. The target refuses a record carrying another generation's claim as a
conflict (see [Current gaps](#current-gaps)).

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

No caller-selected loopback-exposure preparation or equality settlement exists; there is no such type
to construct. Public preparation
accepts an applied cluster cordon, an immutable relay image identity, and semantic targets only. The protected
record is published before runtime creation with a fresh 256-bit operation nonce; managed replacement binds
the inspected relay identity and complete mapping set. Production release removes and re-observes the exact
relay before cluster deletion begins: `releaseRetainedClusterLifecycle` and `runCoreManagedReverse` run the
relay release and then `releaseRetainedCluster` as two separate protected entries. Only the prepared cleanup
call, which has no production caller, refuses inside its own entry while the exposure record exists;
`releaseRetainedCluster` does not check it (see [Current gaps](#current-gaps)). The dated static and live
concurrent-allocation evidence for this boundary lives in the
[cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).

A parent-frame consumer does not retain the child's cluster runtime package after the deployment child exits.
For that case, `observeRecordedClusterExposure` opens the protected store under the cluster's state directory,
reads the exact `<cluster>.exposure` row inside the store's exclusive entry without writing it, admits only a
canonical managed record with one requested service, and re-inspects the recorded Docker relay's name,
immutable identity, operation, specification, and complete loopback mapping set before returning the selected
port. Opening the store creates it when the state directory holds none, so an observation of a cluster that
never recorded an exposure leaves an empty store behind; the target creates nothing and refuses with the
absent-record answer before any store is opened (see [Current gaps](#current-gaps)).
`HostBootstrap.Cluster.Shipped` carries that observation through the unauthenticated frame-child transaction
of `HostBootstrap.Handoff.Transaction` into the provider frame that owns Docker: the request carries no
authority, so its vocabulary admits observations only. Its bounded response is only the freshly observed
port; no cluster handle, ownership witness, credential, or executable selector crosses back.

The compatibility actions in `HostBootstrap.Cluster.Lifecycle` hold none of these clauses.
`ensureCluster` treats any healthy cluster with `clusterName plan` as the desired cluster without checking a
receipt, and deletes and recreates an unhealthy same-name cluster; `clusterDown`/`clusterDelete` issue
`kind delete cluster --name <name>` without proving this plan created or adopted the resource. Their only
production caller is the bare `cluster-live` gate (`clusterCreate` and `clusterDelete`); `project up`,
`project down`, and `project destroy` do not reach them.

### The cluster as a row of the frame table

Beside that backend the cluster also exists as a **row** of the
[frame table](../README.md#glossary) (the frame-table sense of "frame": a provider's frame and the closed
table of facts a context differs by) rather than as a module of parallel logic, and the four modules it is written in are the whole of
it. `HostBootstrap.Cluster.Command` says what to ask — the tool the frame table names, the exact argument
vector, the stdio disposition, and the frame whose process reads it — and declares the four tools a
cluster's commands reach (`Kind`, `Nvkind`, `Docker`, `Kubectl`) in one place, so a driver and the row that
holds its clauses are declared together; `Helm` is required by discovery for chart work but issues no cluster
command. `HostBootstrap.Cluster.Report` says what an answer
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

`project down` and `project destroy` are root-orchestrator commands. `placementAllowsCommand` admits the
`HostOrchestratorCommand` class only when the current frame is the topology's root (`isRootFrame`, derived
from the validated topology graph rather than a config field) and its placement is
`HostOrchestratorPlacement`. `addRole` can widen a context's declared command classes, but not past that
placement-and-root check, so a widened leaf is refused.

Teardown is the recursive reverse command. The root lifecycle entry drives the plan's teardown forest
child-first: it launches each child frame's reverse through the authenticated handoff, runs each frame's
local work in reverse forward order, and stops or deletes a parent's provider only on ascent.
[Composition methodology](../architecture/composition_methodology.md#the-recursive-project-up-interpreter)
is the canonical home for that traversal. Within a frame, the reverse projection selects the local work:

- the frame that owns the `deploy-kind` step runs the core-managed `DeleteCluster` reverse, for Down and
  Destroy alike. At the root that is `releaseRetainedClusterLifecycle`; in a child frame reached by descent
  it is `runCoreManagedReverse`. Both first release the recorded exposure relay
  (`releaseRecordedClusterExposure`) and then run `releaseRetainedCluster`, which re-observes the bound node
  identities under the protected store, deletes through the one interpreter, and forgets the records only
  over a reported absence;
- `deploy-chart` and `expose-port` are released with the cluster that contains them;
- a node's declared reverse stops or deletes its provider or direct resources.

On the direct Linux GPU path the demo declares a reverse that recovers the exact Docker-visible durable
profile bind and invokes a fixed internal entry in the project image; that entry runs
`releaseRetainedCluster`, and the outer frame separately proves every declared node absent.

An exception from a release becomes the ordinary typed failed teardown outcome, so the reverse driver
settles or continues siblings without a second cluster-specific control path. Independent cleanup actions
are attempted and their failures are aggregated. `down` stops provider VMs;
`destroy` deletes them. A failed `project up` unwinds through the same forest, but a hard process kill can
still leave state for a later reconcile.

The prepared provider boundary does not reinterpret Direct as a VM. Direct settles only a plan-local
admission and canonical identity share; provider stop, delete, guest execution, and guest alias are
structured refusals with no physical-host mutation. Direct-lane cluster/container cleanup therefore
remains its own plan work rather than provider teardown.

## Data-path guarantee

The cluster teardown partition excludes the plan's data path from its filesystem removal set:

- `Down` removes no planned filesystem path;
- `Delete` removes the derived state path but not the data path.

For a plan-owned cluster the derived state path is the leaf `<durable root>/cluster/<driver>/state`
(`clusterRuntimeStateDirectoryFor`), beneath the data path, so a workload must not write there; a plan
resolved without plan ownership keeps it at `<project-root>/.cluster/<cluster name>`, outside the data path.
[Durable state](../architecture/durable_state.md#what-lives-under-data) lists what that leaf holds.

This is a narrow and unit-tested guarantee. Root admission derives direct-host `.data` from one
opaque canonical project root, and the Docker handoff consumes a same-root typed host projection.
The core provider-guest alias route reconciles `/var/tmp/hostbootstrap-demo-data` through exact opaque
managed provider/share/alias authority and identity-conditional release. The demo renders the Kind node's
durable bind from that alias as the fixed `durableDockerHostPath` on VM-backed lanes, and from the
Docker-reported bind source of the project container's durable mount on the Direct lane; the plan carries no
typed guest, container, kind/nvkind, or pod projection of the path. Dated live persistence evidence for the
demo lives in [the worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). See
[durable state](../architecture/durable_state.md).

The status renderer's current wording is `(not removed by cluster teardown)`. It describes membership in
the removal partition; it is not a filesystem stat or an end-to-end persistence claim.

## Production and test profiles

The library's `ClusterProfile` has two constructors:

| Profile | Data directory | Cluster identity |
|---|---|---|
| `Production` | `.data` | fixed project name |
| `TestCase runName` | `.test_data/<runName>` | run-scoped Harness name |

The demo's `RunProfile` (`ProductionRun` or `HarnessRun`) is a configuration field that `clusterProfileOf`
projects onto those constructors.

The Harness command admits an exact `ProjectPlan (Harness projectId runId) ...` and owns the generated
config and `.test_data/<runId>` root. The core reverse derives its cluster profile from the plan's own profile
name. The demo's cluster, provider, mount, and teardown consumers instead compute the `ClusterProfile` as
`clusterProfileOf` of the working configuration and the durable root through `ensureProfileDataPath` over
the process working directory, independently of the retained plan (see [Current gaps](#current-gaps)); see
[harness workflow](../architecture/harness_workflow.md).

The target uses an opaque, scope-indexed `LifecycleProfile`. The
[host providers and the lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
supplies backend-indexed opaque managed provider/share/alias authority inside an already admitted exact
plan; it cannot mint a lifecycle profile or command authority. Only the
[sessions, journal, and fences phase](../../DEVELOPMENT_PLAN/phase-10-sessions-journal-and-fences.md)'s protected
mode/lease openers can combine that authority with the exact active Production or Harness mode. Fresh
plans require the still-unbound lease and produce `LifecycleProfile (Production projectId)` or
`LifecycleProfile (Harness projectId runId)`. Configful abandoned Production `ProjectUp` instead requires
the exact bound lease/snapshot/recovery tuple and yields only its indexed
`RecoveredProductionLifecycleProfile`; Harness/teardown cannot inhabit it. `withProjectPlan` consumes a
fresh profile and scope-matching config. The exact plan therefore retains the right scoped profile/root
identity, but the demo's `containerPlan` accepts a separately config-derived `ClusterProfile` and source
root rather than a projection from that exact plan. See
[lifecycle state model](../architecture/lifecycle_state_model.md#lifecycle-profile-authority).

## Resource limits

CPU and memory are applied to kind/nvkind node containers with `docker update`, and `--memory-swap` is twice
the memory limit, not equal to it. The owned-cluster backend applies the whole cluster slice to every node
container rather than dividing it, so an N-node cluster's aggregate cap is N times its slice; only the
compatibility `clusterCreate` path divides the slice per node. Bare Linux has no implemented storage quota or
image-garbage-collection cap; storage is only capacity-checked before bring-up. VM-backed lanes receive
provider storage walls when a new Lima/Incus VM or WSL distro is created, but existing VM/VHDX sizes are not
uniformly observed, resized, or refused when config changes. No production path runs the `Cluster.Budget`
workload-fit and partition chain, and the static `fitsBudget`/`demoPods` example is not the applied
authority. [What runs today](resource_budgeting.md#what-runs-today) is the canonical statement of the applied
controls and their gaps.

## Current gaps

- The owned-cluster cordon applies the whole cluster slice to every node container. That defect is owed by
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md);
  [resource budgeting](resource_budgeting.md#current-status) states it canonically.
- `discoverStrongClusterBackend` does not require `Kind` on an nvkind plan although listing, kubeconfig
  readback, and deletion run through it, so a missing `Kind` fails at the first such effect instead of at
  discovery. The backend belongs to
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- `releaseRetainedCluster` does not refuse while the cluster's exposure record exists; production relies on
  its callers releasing the relay first. That check is owed by
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- The bare `cluster-live` gate drives the compatibility actions, so no live gate exercises the ownership
  backend's records, identity binding, or conditional release. The gate belongs to
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- The backend's described commands run through `interpretHostCommand` with no per-command deadline or
  process-group reaping, and the compatibility actions through `runTool`; the bounded cluster interpreter is
  owed by
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- The readiness call stamps a ready answer with the managed handle's identity rather than the identity it
  re-observed, so a cluster recreated under a fresh record after the cordon can advance the readiness counter.
  Stamping the re-observed identity is owed by
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- The cluster and node standings do not compare a record's claim with the plan's, so a plan whose
  configuration changed adopts the previous generation's records. The claim check is owed by
  [the cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- `observeRecordedClusterExposure` opens, and so creates, the protected store before it finds no exposure
  record. The non-creating observation is owed by
  [the worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).
- The demo's cluster, provider, mount, and teardown consumers take their `ClusterProfile` from
  `clusterProfileOf` of the working configuration and their durable root from `ensureProfileDataPath` over
  the process working directory (`runVmUp`, `runCopySource`, and `withHostAcceleratorExposure` each do
  both), `containerPlan` takes that profile with the context's source root, and the guest-alias, kind-node,
  and pod durable paths are fixed demo constants, rather than every term being a projection of the retained
  exact plan. Those consumers belong to
  [the worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

## Validation

From the repository root, the exact
[cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
gate is:

```sh
(cd core && cabal test all) && hostbootstrap test run cluster-live
```

The static leg covers the exact plan-owned precondition, reconcile-result, ownership-receipt, same-name
foreign-cluster, readiness, status, and teardown cases declared by the phase. The independent live leg covers
fresh creation, bounded readiness, a read-only status observation, deletion, labelled-node absence, and
durable-sentinel survival on linux-cpu, through the compatibility actions. It deliberately has no demo
dependency.

Recursive child-to-parent lifecycle traversal, the run-scoped demo cluster, end-to-end pod/host durable
readback, GPU daemon placement, and substrate-specific storage-wall acceptance are evidenced by
[the worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) and the substrate acceptance phases,
not by the gate above.

`DEVELOPMENT_PLAN/README.md` owns phase status and closure evidence.

## Related

- [durable state](../architecture/durable_state.md) — `.data`, the stable alias, and persistence gate.
- [harness workflow](../architecture/harness_workflow.md) — test DSL and profile defects.
- [resource budgeting](resource_budgeting.md) — applied and missing resource walls.
- [in-cluster registry](in_cluster_registry.md) — S3 store, registry, and image-push ordering.
- [accelerator daemon](accelerator_daemon.md) — substrate-selected daemon placement.
