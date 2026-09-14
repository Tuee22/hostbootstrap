# Network Reachability and Registry Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../engineering/in_cluster_registry.md](../engineering/in_cluster_registry.md), [composition_methodology.md](composition_methodology.md), [../engineering/derived_project_standards.md](../engineering/derived_project_standards.md)

> **Purpose**: Define the typed endpoint-reachability and blob-delivery doctrine that prevents a
> registry client from being redirected to an endpoint outside its network scope.

## TL;DR

An endpoint is not `Text`; it carries the network scope from which it is reachable. A registry plan
jointly binds its client, published exposure, backing store endpoint, and blob-delivery strategy.
Local publication is a runtime-owned resource: configuration names a semantic service and stable
cluster-internal target, the container runtime atomically assigns a loopback port to an identity-bound relay,
and authenticated inspection of that exact relay produces the endpoint clients consume. The selected port is
never a Dhall value or a canonical Kind/nvkind input.
Redirect delivery is constructible only with proof that the client can reach the backing endpoint.
When a host-local Docker client reaches a published registry backed by cluster-only MinIO, the only legal
delivery is `proxyThroughRegistry`, and the renderer necessarily emits `redirect: disable: true`.

The two owning modules are
[`HostBootstrap.Network`](../../core/hostbootstrap-core/src/HostBootstrap/Network.hs) and
[`HostBootstrap.RegistryPlan`](../../core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs).
They are the signature reference; this document describes their contracts without maintaining a
second set of illustrative signatures that can drift from the compiled API.

## Current Status

**The generic algebra and resolved-endpoint boundary are implemented.** The scope is a
type index, `Reachability` is a closed GADT with no host-local-to-cluster-only constructor, the redirecting
`BlobDelivery` constructor takes that witness, `RegistryPlan` is opaque behind topology-specific
constructors, and the `storage.redirect` stanza is derived from the delivery rather than chosen beside it.
`Exposure`, `RegistryPlan`, and `ReadyBlobRoute` retain nominal lifecycle-scope, plan, cluster, and
service indices. Route settlement compares the exact service, runtime-selected port, relay identity, cluster
generation, and ownership operation. Compile-fail fixtures pin the forbidden constructions and role coercions.

**The demo registry delivery and application clients use the resolved-endpoint boundary.** Its finalized
registry plan selects proxy delivery, so generated registry configuration disables redirects to cluster-only MinIO.
The cluster backend removes host publication from Kind/nvkind rendering, creates one owned relay on the
cluster container network, lets the container runtime assign its loopback host ports, and is the only producer
of authenticated resolved exposures. The worked demo carries those values lexically to MinIO initialization,
registry deployment and image push, web readiness, and host-resident accelerator ingress; none reconstructs
an endpoint from a number.

The [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns the generic reachability/delivery algebra and finalized registry plan. The
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the demo renderer, adoption, and live
proof. The [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
and [prepared-operations phase](../../DEVELOPMENT_PLAN/phase-11-prepared-operations.md) supply the
identity-bound runtime observation consumed by the push operation.

## Scopes

`NetworkScope` is a closed kind, not a hostname convention. It has exactly the three scopes the
composition chain crosses:

| Scope | Where a name in it resolves |
|---|---|
| `HostLocal` | on the machine running the project binary |
| `VmLocal` | inside the provider VM guest |
| `ClusterOnly` | only from inside the cluster network |

There is no public scope: nothing in this project publishes beyond the host, and a tag with no
producer would be a definition-only surface. `ScopeName` is the term-level tag a scope-indexed value
carries so it can report its own index, and `scopeNameOf` projects it.

`Endpoint` is indexed by the scope its authority resolves in and is opaque. `endpointAuthority` and
`endpointScope` read it; `clusterOnlyEndpoint` is the one mint, and it validates the authority as a
bare `host:port` — rejecting empty, whitespace-bearing, scheme-bearing, and path-bearing text with
`InvalidEndpointAuthority`. Code must not infer scope by searching for `.svc`, `localhost`, or an IP
substring. A client spelling of `localhost` is also not proof that the listener is loopback-only.

`NetworkClient` is indexed by the scope it dials *from*, with one value per scope:
`hostLocalClient`, `vmLocalClient`, and `clusterOnlyClient`. `clientScope` reads it back.

For the worked demo, the pure cluster renderer declares registry, web, accelerator where applicable, and
MinIO as semantic services with stable cluster-internal targets. It emits no host-side port number and no
Kind/nvkind `extraPortMappings`. VM-backed rendering retains the selected writable durable mount; Direct
nvkind rendering adds only its GPU worker topology and invents no VM/share layer.

After the exact cluster is Ready, the cluster backend creates a relay from the authenticated derived project
image on that cluster's container network. Each relay listener forwards to its declared internal target, and
Docker publishes it as loopback-only without a requested host port. Runtime creation therefore chooses and
retains the binding in one operation. The backend inspects the exact relay container identity and refuses a
wildcard, missing, additional, duplicate, wrong-protocol, or wrong-target mapping before producing any local
endpoint.

## The reachability relation

`Reachability` is a closed GADT over a client scope and an endpoint scope, and every legal pair is one
of its four constructors:

| Constructor | Client scope | Endpoint scope |
|---|---|---|
| `HostReachesHost` | `HostLocal` | `HostLocal` |
| `VmReachesVm` | `VmLocal` | `VmLocal` |
| `VmReachesCluster` | `VmLocal` | `ClusterOnly` |
| `ClusterReachesCluster` | `ClusterOnly` | `ClusterOnly` |

The absent case is the point of the module: there is no constructor taking a `HostLocal` client to a
`ClusterOnly` endpoint, because a host-local client genuinely cannot resolve an in-cluster Service
name. The bad redirect is not a runtime error to be checked; it is unrepresentable.
`reachabilityClientScope` and `reachabilityEndpointScope` project the indices, and `reachableFrom`
is the term-level view of the same relation for rendering and diagnostics — it agrees with the GADT
by construction, because every `True` pair has a constructor.

A future provider may add a reachability proof only when it can verify a real route; it must not add
a coercion or a string-based escape hatch.

## Ports

A port is a value, and the range `1..65535` has one definition. `Port` is opaque and `mkPort` is its
only mint, so "this integer is a port" is a property of the value a consumer holds rather than of
whether some earlier caller remembered to check.
[`HostBootstrap.Network.Port`](../../core/hostbootstrap-core/internal/network-port/HostBootstrap/Network/Port.hs)
declares it in a leaf module so the cluster backend that resolves an exposure and the runtime
dependency package that ships one can sit above the same definition;
[`HostBootstrap.Network`](../../core/hostbootstrap-core/src/HostBootstrap/Network.hs)
re-exports `Port`, `mkPort`, and `portNumber`, because the reachability vocabulary is where a reader
looks for what a port is.

The rule this replaces is worth stating, because it is the failure mode a shared vocabulary exists to
prevent: the same `port > 0 && port < 65536` predicate was written four times, in four modules, over
`Int`. The four agreed, but nothing made them agree, and no consumer could tell which of its integers had
been past one of them. A consumer that wants the boolean now asks the producer for the value and reads
whether it arrived; a consumer that holds a `Port` needs no check at all. `portNumber` is the single exit,
for a wire field, an argument vector, or a rendered authority.

The exposure, registry, and runtime-dependency surfaces carry `Port`: the resolved exposure's host and
target ports, the plan's exposure intent, the published port a blob-route observation dialled, and the
exposure rows a runtime dependency package renders and verifies.

## Exposure identity

An exposure is how a scope is *made* reachable; it does not by itself grant reachability from another
scope. `Exposure` is opaque and carries five indices beyond its scope — the network scope, then the
nominal lifecycle scope, plan, cluster, and service — so a value minted for one plan or cluster
generation cannot be spent against another. `exposureEndpoint`, `exposurePort`, `exposureService`,
and `exposureRuntimeIdentity` are its readers; a `localhost` authority supplied as text cannot become
one, because the only mints are the two below.

| Mint | Produces | Retains |
|---|---|---|
| `resolvedHostExposure` | a `HostLocal` exposure from a `ResolvedExposure` | relay identity, cluster generation, ownership operation |
| `resolvedVmExposure` | a `VmLocal` exposure from the same | the same three |
| `clusterServiceExposure` | a `ClusterOnly` exposure from a service name and port | no runtime identity — a Service address needs no relay |

`ResolvedExposure`, declared by
[`HostBootstrap.Cluster.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs),
is the runtime-inspected value the two local mints consume. Its hidden constructor binds the service,
selected loopback port, internal target and target port, relay container identity, cluster generation,
and ownership operation. It is carried with the cluster dependency package and freshly re-inspected
when opened. It is never serialized back into Dhall, cached as a conventional endpoint, or recreated
from a number. Stable Kubernetes Service/NodePort values are internal targets and do not imply a
same-number host publication. `exposureRuntimeIdentity` returns those three retained fields for a
resolved local exposure and `Nothing` for a cluster-service one.

Scanning for a free port and then closing the probe is not supported: the gap before the real bind admits a
race. The same rule excludes treating a launcher-specific `hostPort: 0` expansion as allocation when that
launcher first selects and releases a candidate. The component that retains the binding must choose it.

## Blob delivery

`BlobDelivery` is indexed by the scope of the client it answers, and it has exactly two mints.
`proxyThroughRegistry` needs no proof: the registry streams the bytes itself, so the client never
learns the store's address. `redirectToStore` takes a `Reachability` witness and the store endpoint,
and that witness is the whole gate — none exists for a host-local client and a cluster-only store, so
the constructor is simply unavailable for that pair. `blobDeliveryStrategy` projects the term-level
`DeliveryStrategy`, either `ProxyBlobs` or `RedirectBlobs` carrying the store authority and the scope
it resolves in.

Therefore a host Docker client cannot be paired with redirect delivery to cluster-only MinIO.

## The finalized registry plan

`RegistryPlan` is opaque, indexed by client scope, store scope, and the nominal lifecycle scope, plan,
cluster and service indices. It is reachable only through a topology-specific constructor, so no
caller can assemble a registry endpoint and a store endpoint independently and pair them by
convention.

| Constructor | Topology | Delivery it fixes |
|---|---|---|
| `hostServedRegistryPlan` | a registry published on the host or VM loopback, blobs in a cluster-only store | `proxyThroughRegistry`, by construction |
| `inClusterRegistryPlan` | clients inside the cluster | `redirectToStore`, from the witness the caller supplies |

Both refuse a zero revision with `InvalidRegistryRevision`; a revision is strictly positive and
generative. `registryPlanClient`, `registryPlanExposure`, `registryPlanEndpoint`, `registryPlanStore`,
`registryPlanDelivery`, and `registryPlanRevision` read the finalized value. There is no independent
redirect boolean, no raw store-authority field, and no post-construction setter.

## Rendering rule

`renderStorageRedirect` is total over the finalized plan and takes the delivery as its only input:

| Delivery strategy | Rendered `storage.redirect` stanza |
|---|---|
| `ProxyBlobs` | `redirect:` / `disable: true` |
| `RedirectBlobs` | nothing — Distribution's own redirecting default stands |

For the demo topology the storage section reads:

```yaml
storage:
  redirect:
    disable: true
  s3:
    regionendpoint: http://minio.default.svc:9000
```

The boolean is serialized output, not a DSL choice. Registry exposure and the MinIO endpoint are
rendered from the same plan, so separately supplied manifests cannot disagree about scope or identity.

## Runtime admission

Types prove the declared topology is coherent; runtime observations prove the deployed topology matches
the declaration. Before image push, the interpreter verifies:

1. the exact client can reach the registry exposure;
2. the registry workload can reach the exact object-store endpoint and bucket;
3. a probe blob written through the registry can be queried through the registry without an
   out-of-scope redirect;
4. the response identifies the expected registry, store, plan, and deployment revision.

The observation is a `BlobRouteObservation`, carrying the `BlobProbe` that was issued, the service and
`Port` dialled, the runtime identity triple, the status, any `Location` authority with the scope it
resolves in, and the revision. `settleBlobRoute` mints a `ReadyBlobRoute` from it, and refuses in
order: an `ApiVersionProbe` rather than a `BlobHeadProbe` is `BlobRouteNotABlobProbe`, because a bare
`GET /v2/` proves only that the registry HTTP process is serving; a revision other than the plan's is
`BlobRouteStaleRevision`; and a different service, runtime identity, port, or delivery outcome is a
`BlobRouteMismatch`. A redirect is acceptable only for a plan whose delivery is `RedirectBlobs`.
`readyBlobRouteRevision` reads the settled revision back, and the witness cannot be reused across a
replacement revision.

The prepared push adapter requires that exact readiness value through the plan-owned precondition set.

The probe sequence is rendered by four additive Lift leaves with fixed argv: upload-session `POST`,
octet-stream `PATCH`, digest-completing `PUT`, and non-following blob `HEAD`. Tests pin every argument,
including timeouts, headers, payload position, and status/redirect output. Registry authentication remains
higher policy: `HostBootstrap.Registry` consumes the generic Lift and its quoting rule. Authenticated
descent and the sanitized lifecycle route likewise delegate crossing argv to `foldLeaf`; no registry or
route module owns a competing provider renderer. The registry policy folds the container invocation first,
then folds its provider crossing around a leaf which reads the credential from stdin into the transient
forwarding environment. Neither fold receives the credential payload; the existing stdin runner supplies
it only when executing the plan. Incus, Lima and WSL2 share this path, and unsupported layer shapes return
no authenticated plan.

## Invalid states

These states have no public constructor:

- a host-local client plus a cluster-only backend plus redirects;
- endpoint text substituted across host/VM/cluster scopes;
- registry exposure and object-store endpoint assembled from different plans;
- raw redirect booleans that contradict delivery strategy;
- readiness based only on `/v2/` while the blob route is broken;
- a readiness observation reused after registry, store, revision, or route replacement.

## Validation

Closure requires:

- compile-fail tests rejecting every invalid combination above;
- constructor/property tests covering all supported reachability pairs;
- golden tests proving rendering is uniquely derived from delivery strategy;
- negative runtime tests where `/v2/` is Ready but blob `HEAD` returns an illegal `307`;
- a live host-client to resolved relay exposure to internal NodePort registry to cluster-only MinIO push,
  repeated push, pull, registry-pod
  restart, and tag lookup;
- assertions that proxy mode exposes no cluster-only MinIO URL to the client.

See [in-cluster registry](../engineering/in_cluster_registry.md) for the demo topology and
[composition methodology](composition_methodology.md) for integration into the single project plan.
