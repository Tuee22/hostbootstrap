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
identity, for both verbs. The bare `cluster-live` gate uses the same prepared backend and retained
release. The cluster-node cap divides the slice across its declared nodes; see
[resource budgeting](resource_budgeting.md#what-runs-today).

The cluster modules divide the work as follows:

| Module | Owns |
|---|---|
| `HostBootstrap.Cluster.Lifecycle` | plan types (`ClusterPlan`, `PlanOwnedClusterConfig`, `AcceleratorIngressPlan`), the teardown partition, and shared pure NVIDIA decisions |
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
The independent live gate consumes the same exact ownership checks. Kind creation carries a finite ten-minute driver readiness
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
could be empty, so reading it is total. The pure teardown partition returns a refusal if the
derived removal path lexically equals or contains the durable root. Empty, parent-segment, and mixed
relative/absolute paths are refused because their relationship is ambiguous. Filesystem alias and symlink
resolution remain the responsibility of the ownership backend that performs actual deletion. Harness run-key
admission uses `mkTestCaseProfile`: a nonempty key of at most 48 ASCII letters, digits, or hyphens.
`clusterProfileRunKey` projects it without exposing the profile representation. The unchecked Harness constructor is private. The bare CLI validates the run key
before constructing either its live plan or a retained plan. The demo refines Harness run
keys during Dhall decoding and programmatic assembly, retaining the admitted cluster profile while
preserving the same serialized text representation. Demo commands branch on the pattern-free
`clusterProfileRunKey` accessor rather than inspecting the Harness constructor. Listing,
kubeconfig readback, identity binding, and conditional deletion use Kind after either creator. Only the
cluster listing requests Kind's quiet mode. Creation and deletion classify process exit status while
preserving the first error line on refusal, and accept ordinary progress on either captured stream.
Kubeconfig readback also classifies exit status before validating the strict document body. A successful
mutation derives authority from fresh kubeconfig readback and every declared node-container identity,
never from progress text. Docker node-name filters quote every dot before anchoring both ends, so a
literal dotted name cannot select a similarly spelled container. The accelerator
gate runs before the cluster package is registered, so downstream workloads cannot confuse Ready nodes with
accelerator readiness; the plugin and GPU workload both select nvkind's verified `nvidia` RuntimeClass.

The [cluster lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
has an independent live linux-cpu gate, reached as a case behind the fixed `test` verb:
`hostbootstrap test run cluster-live`. Its exact Harness plan reserves a Direct provider and re-probes
its carried running dependency before creating, cordoning and readying a plan-owned Kind cluster.
All assertion commands use the bounded cluster interpreter, and Kubernetes observation uses the run's
private kubeconfig. The case removes both named exposure containers after stopping their creation workers,
including when creation is interrupted; assertion failures retain their reasons. Exact
reverse releases recorded cluster identities, checks labelled-node absence and re-reads the durable
sentinel outside cluster state. The exclusive run, lease, run-ownership cleanup and report card come
from the harness. The case does not
invoke the demo; demo lifecycle integration and end-to-end durable readback are evidenced by the
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), not by this gate.

The exact prepared cluster adapter produces plan/resource-indexed readiness and ownership settlement.
Convenience `IO ()` waits are descriptive and cannot mint those authorities. See
[readiness](../architecture/readiness.md) and the [lifecycle state model](../architecture/lifecycle_state_model.md).

The project declares Kind or nvkind when `withPlanOwnedCluster` or `withExecutionOwnedCluster`
joins the exact cluster and provider resources to their budget slice. The resulting package retains
that driver in its resolved plan. `withPlanOwnedClusterConfig` derives the driver, paths and node
mapping from that package and validates the rendered material; it accepts no separate driver and
does not rewrite the declaration's driver or node set. The demo's config binder uses the same
retained choice. Owner identity, project name and durable root still come from the admitted plan or
execution package.

Creation retains those canonical bytes and their SHA-256 in the ownership descriptor. Inside the
exclusive entry, it writes a private config beside the temporary kubeconfig, reads it back and verifies
its digest before issuing the create command. The driver receives that private config path; edits or
removal of the consumer's plan-derived file cannot change the prepared creation. Both staging files
and their private directory are removed on success or refusal.

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

The prepared reconcile, cordon and readiness calls hold the protected entry throughout their
ownership observation and effects. They return descriptive backend call results for exact settlement.
`ClusterCreated` or `ClusterRecovered` surfaces as `ClusterResultCreated`, while an already-owned
cluster is healthy only when every bound node container runs. Retained cleanup is the single release
route: `releaseRetainedCluster` derives one `RetainedClusterProjection` at entry. This ordinary
view contains only the cluster name, declared node names, state directory and kubeconfig path; it
retains no durable root and grants no ownership authority. Release reads those coordinates to open
the same state store, then recovers the recorded claim and compares bound identities under one entry.
Released or already-absent state returns `Right ()`; uncertainty
or refusal preserves the records and returns a typed failure (see [Current teardown](#current-teardown)).

- **reconcile** answers `ClusterResultCreated`, `ClusterResultHealthy`, `ClusterResultUnhealthy`, or
  `ClusterResultForeign` — the `ClusterReconcileResultView` cases, whose remaining constructor
  `ClusterResultProbeFailed` reports a probe that could not answer at all. A cluster this record already owned
  is asked one further question the creation path does not need — whether every node container the record
  bound is still running — because that is the container runtime's answer rather than the API server's, and
  an owned cluster whose containers are stopped is a conflict an operator resolves rather than something to
  recreate. Something standing at the name under no durable record of this project's is `Foreign` and is
  never adopted.
- **cordon** applies the one budget renderer's wall to each bound container identity and reports a container
  that took a node's name as a replacement. Every node receives its floored share of the cluster slice
  (see [Resource limits](#resource-limits)).
- **readiness** is read-only and versioned: the transaction carries its re-observed control-plane identity
  with the API and declared-node outcome. The counter advances only when that actual identity equals the
  managed handle's and every declared node is ready. A cluster released and recreated under a fresh record
  after the cordon returns `ClusterNotReady` naming the new identity, without advancing the counter.
  A node replaced during the transaction likewise names the observed replacement for settlement.
- **cleanup** re-observes every owned node, removes the cluster through the one interpreter, and forgets a
  record only over a reported absence, leaving a same-named replacement standing.

What a configuration drift changes is upstream of the backend: the ownership identity is derived from the
plan's own stable snapshot digest, of which the rendered cluster configuration is part, so a plan whose
configuration changed presents a different identity and mints a different claim. The records are keyed by
cluster and node name. The standing decisions (`clusterStanding`, `nodeStanding`) compare each record's
claim with the expected plan-generation claim before accepting either a bound or unbound standing.
Another generation's record is a conflict even when its node identity matches. Retained cleanup uses the
stored claim through the same checks, and record retirement preflights every node record before changing
any of them.

The read-only status path is outside every clause because it mutates nothing: one described command through
the one interpreter and one projection of the cluster report vocabulary's own total classification. Its
refusals stay exactly as narrow — a command that produced no child, a non-zero exit, anything on standard
error, a body that does not end in exactly one newline, a carriage return, a byte outside ASCII, an empty
row, a name outside the portable alphabet, and a repeated name are each the driver contradicting itself, and
each is a refusal rather than an absence, because an absence authorizes creation and a refusal must not.

The exact package layer accepts only a backend-minted Running-provider dependency and reruns that
backend's real probe before offering the cluster call. Production and Harness config bytes are bound
by SHA-256 with the exact retained budget; creation stages and verifies those bytes before passing its
private `--config` path. Successful cordon plus a fresh real API/all-node Ready observation of the exact
owner/container identity produces `ClusterReadiness`. A replacement is a `Conflict`, and observation
version exhaustion refuses instead of wrapping.

A successor recovers readiness only through the backend's exact canonical/runtime package join.
The hidden observation module verifies the carried resource, logical generation, response commitment,
nonce and positive observation version before its private producer can reconstruct readiness.
Every recovered reprobe invokes the actual registered service with a fresh sequence nonce and verifies
the reply again. A caller cannot import `withRecoveredClusterReadiness` through the public facade or
supply an ordinary version to construct authority. Raw backend results and managed, cordon, readiness,
cleanup and running-provider authorities retain private constructors and nominal indices.

Chart reconciliation uses Helm's `--rollback-on-failure` contract together with an explicit `--wait` boundary.
The captured-command classifier still requires an empty standard-error stream on success; avoiding Helm's
deprecated `--atomic` spelling keeps the supported rollback behavior without treating a warning as a settled
workload result. On Helm 4, a first install settles only when the exact install announcement is accompanied by
the matching release name, `deployed` status, revision 1, and `Install complete` description; an incomplete or
otherwise unfamiliar zero-exit result remains a failure.

Alongside it, `HostBootstrap.Cluster.Backend` owns automatic local exposure. A plan supplies only
semantic service identity and the stable cluster-internal TCP target. After readiness the backend starts
an identity-bound relay on the cluster container network and asks the container runtime to publish each relay
listener on `127.0.0.1` without a host-side number. Runtime creation is therefore both selection and binding;
there is no scan-then-bind window.

Intent construction and managed-record readback use the same service grammar: a non-empty identity
of at most 128 characters, without NUL, path separators, colons, line breaks or tabs. A declared target
host cannot be empty or contain spaces, and its internal TCP port must be in 1..65535. These checks
run before a backend is entered, so every admitted service identity can be reopened from its record.

Only inspection of the exact relay/container identity may mint `ResolvedExposure`. It binds the selected port
to the plan, cluster generation, service, internal target, and ownership operation, and it travels through the
matching cluster dependency package rather than Dhall or canonical cluster YAML. Recovery re-inspects the
mapping, while release removes the relay by identity before deleting the cluster. Wildcard, missing,
additional, duplicate, changed-target, or replacement mappings are `Conflict`.

Inspection distinguishes a running relay from an authenticated stopped relay. A stopped relay's
empty publication map is accepted for release only after its exact identity, name and ownership
labels match. It cannot mint a resolved endpoint. Reconcile releases that stopped owned relay and
its record, then recreates it with a fresh operation, container identity and runtime mappings under
the same protected entry. A fresh creation already reported stopped returns a bounded retryable
failure; a later invocation can recover its pending record.

Port inspection ignores Docker's null entries for image EXPOSE ports and still requires every
non-null binding to match the expected listeners exactly. Creation requests quiet output and
accepts successful pull progress on standard error only alongside an exact container-identity line;
authenticated inspection still precedes publication. Invalid UTF-8 and noncanonical ownership rows
are Conflict refusals. A failed removal keeps the relay and durable record available for retry.

No caller-selected loopback-exposure preparation or equality settlement exists; there is no such type
to construct. Public preparation
accepts an applied cluster cordon, an immutable relay image identity, and semantic targets only.
Image admission accepts a canonical SHA-256 image ID or a named SHA-256 reference with one
non-empty repository path, optional registry/decimal port and tag. Path components are lowercase ASCII,
with Docker's separator grammar; the remote path is at most 255 characters and a tag at most 128.
Empty repositories, option-like names, malformed separators and repeated digest suffixes refuse before
an exposure record or runtime effect. The syntax follows the
[Distribution reference grammar](https://github.com/distribution/reference/blob/main/regexp.go), which
[Docker's image reference documentation](https://docs.docker.com/reference/cli/docker/image/tag/) names
as canonical.
The relay entry is owned by the private `cluster-exposure-internal` Cabal library, shared with the
core package tests. It uses one bracketed listener set and scoped worker groups that close admission,
shut down and close the owned sockets, cancel workers and wait for their finalizers. A later bind failure closes earlier listeners. Relay
cancellation also closes accepted sockets and both copy directions before returning. A clean EOF
half-closes the opposite socket's send side and waits for the response direction; an exception ends
the connection. The accept loop immediately retries interrupted or aborted connections, backs off
on descriptor exhaustion or an unclassified error, and stops for an invalid listener. These paths
are checked with real in-process loopback sockets and errno values by `ExposureRelaySpec`.

The protected
record is published before runtime creation with a fresh 256-bit operation nonce; managed replacement binds
the inspected relay identity and complete mapping set. Production release removes and re-observes the exact
relay before cluster deletion begins: `releaseRetainedClusterLifecycle` and `runCoreManagedReverse` run the
relay release and then `releaseRetainedCluster` as two separate protected entries. The retained cluster
transaction independently refuses while any exposure record exists inside its own protected entry, so
relay-first ordering is enforced at the destructive boundary. A driver refusal or retained node preserves
the cluster records. The dated static and live concurrent-allocation evidence for this boundary lives in the
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
the memory limit, not equal to it. The owned-cluster backend and descriptive creation path both use
`clusterNodeBudgetShare` to divide every budget dimension by the exact node count with integer floors.
A dimension smaller than the count refuses before any update, and aggregate node caps stay within the
cluster slice. Bare Linux has no implemented storage quota or
image-garbage-collection cap; storage is only capacity-checked before bring-up. VM-backed lanes receive
provider storage walls when a new Lima/Incus VM or WSL distro is created. The owned Incus and Lima
provision transactions compare native CPU, memory and disk limits with the declaration and refuse drift
without mutation. WSL provisioning records the original requested VHD cap before installation and
requires equal storage on re-entry; changed storage conflicts without reinstalling. That record does
not claim a fresh physical VHDX-capacity observation. No production path runs the `Cluster.Budget`
workload-fit and partition chain, and the static `fitsBudget`/`demoPods` example is not the applied
authority. [What runs today](resource_budgeting.md#what-runs-today) is the canonical statement of the applied
controls and their gaps.

Backend discovery requires every tool in the selected driver's declared command catalog. Source guards
check the actual ownership import and the hidden backend capability's exact field types.

## Current gaps

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
durable-sentinel survival on linux-cpu. Its Harness plan reserves a real Direct host provider,
re-probes the carried running dependency, then creates, cordons and checks the cluster through the
prepared owned backend. Reverse cleanup consumes retained ownership records; assertions use the
private run kubeconfig and the shared bounded interpreter. It has no demo dependency.

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

The owned cluster driver and backend share one bounded command interpreter. It preserves the
closed command's resolved launch and UTF-8 standard input through the existing grouped runner,
inside the actual captured working directory and environment. Kind and nvkind creation have a
660-second wall beyond their rendered ten-minute wait; Helm has 600 seconds and an explicit
five-minute Kubernetes wait has 360 seconds. Other cluster queries, inspections, updates and
deletions have 60 seconds. Every row bounds each output stream to 4 MiB and termination grace
to two seconds. Completed captures retain their exit and both streams; timeout, output overflow
and execution failure produce named refusals, never an empty successful listing. Pure decisions
and source-flow checks connect this policy to the shared runner's actual kernel timeout, escalation,
backpressure and child-reaping cases. No stand-in Kind command is execution evidence.

The independent gate pins its Kind node image by digest and renders an InitConfiguration patch
with a finite five-minute Kubernetes API bootstrap timeout. This fits inside the ten-minute Kind
creation wait and its 660-second process wall. Cold container snapshot creation may exceed kubeadm's
one-minute API default before the API server starts. The setting uses the upstream
[kubeadm timeout field](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/).

Read-only status uses one bounded Kind listing and the shared total listing classifier. The prepared
entry validates its backend binding; `runRetainedClusterStatusCall` reads only the retained plan's
cluster-name projection. Neither entry opens an ownership store or produces a resource witness. The
independent live gate snapshots actual protected record bytes and stable node-container identity,
state, configuration and published ports around status before creation, after readiness, and before
and after release. Every observation must leave those snapshots equal; presence and absence remain
valid observations, and a probe failure cannot become absence.

### Report framing and readiness observations

The node-list classifier refuses non-ASCII or oversized documents before JSON decoding, and compares
unique node names as a set, independent of the API server's report order. Shared line-framing cases
assert their exact refusal directly, so a cluster-name grammar cannot accidentally establish framing.
A kubectl command that never launches is a typed report refusal, so the ownership and strong backend
report probe failure rather than not-ready. A launched query's failed exit or noisy success retains its
bounded first diagnostic line in the API-unready result. The private strong observation carries that
diagnostic beside the exact managed identity. Settlement compares identities before classifying the
not-ready refusal; a replacement remains a conflict, and a matching API-unready observation is retryable
only after a fresh probe. The descriptive readiness view passes the identity and diagnostic to the bare
and demo bounded polls, and a runtime dependency refusal retains the same message. The pure
`clusterApiNotReadyRefusal` returns only an error and grants no readiness authority.

### Actual generation refusal assertions

The bare live suite asks the ownership transaction to reconcile its actual already-Ready cluster under
a deliberately different generation owner. It requires the named generation conflict and compares the
exact protected-record and immutable container snapshots around the attempt. A second assertion observes
an independent name and worker absent through the real Kind/Docker tools, publishes a matching unbound
root record and another generation's worker record through real protected CAS, and verifies that record
retirement refuses without changing either record's bytes or version. These records live in the gate's
own temporary store and name no created provider object. The original cluster still follows its ordinary
retained reverse, node-absence and sentinel assertions. No provider executable substitutes for the real
tools in either assertion.

Cleanup re-enters the root's retained generation claim and each declared node's record. A missing bound
container is a removal to finish; a different identity remains a refusal. A surviving bound node is
actually re-observed before issuing the delete. When all declared containers are absent, release finishes
through the ownership primitive's retained-removal operation without issuing another delete. Worker
records retire before the root record. Orphan worker metadata is retired only after every declared node
name is observed absent and all remaining records pass the same generation check.

The retained backend requires its cluster ownership record before asking any provider tool. A missing
record is the named permanent refusal "the cluster ownership record is absent". This preflight leaves
the direct ownership API's idempotent empty release and orphan-worker cleanup intact. When an accepted
delete leaves a bound node present, the total node-completion decision retains every record and the
backend requires a fresh probe before retrying. A replacement or unclaimed present identity refuses
record retirement.

Supplementary owned-cluster fixture checks assert successful setup before the operation under test,
then compare the complete re-entry or replacement refusal. Readiness and cordon preserve the named
missing-listing refusal, and refused release preserves the exact root and worker record set, bytes and
versions. Authored replies establish compatibility; direct pure classifications and actual cluster runs
supply their respective decision and provider evidence.

Backend admission uses `clusterDriverTools`, derived from the canonical representative command catalog
`clusterDriverCommands` plus the Helm chart client. Kind requires Kind, Docker, Kubectl and Helm;
nvkind also requires Nvkind while retaining Kind for listing, credential readback and deletion. The
catalog contains ordinary described values, and runtime callers provide actual plan parameters to the
same renderers. Source guards cover physical public and private direct cluster-command modules,
including inline backend Helm, Docker and Kubectl calls. Nested host-capacity foundations retain their
own platform declarations for probes such as df and sysctl.

Forward and retained cluster calls share canonical target validation before their protected store opens.
That validation derives every worker key as well as the root and exposure addresses through the
protected-store constructors. Bounds apply to the encoded namespace and tuple, so individually admitted
node names can still produce an over-bound key. Such a target is a permanent refusal and creates no
cluster state directory or partial record set.

Already-owned reconciliation performs its ownership and container-running observations in one protected
entry. The same session and owned descriptor reach both checks, and the healthy or unhealthy observation
is classified before the entry releases. Initial creation, recovery, foreign-object refusal and probe
failure retain their distinct results through that same transaction.
