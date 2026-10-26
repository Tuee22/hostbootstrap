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
When a host-local Docker client reaches a published registry backed by a cluster-only S3 store, the only legal
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
service indices. Route settlement compares an observation's service, published port, relay identity, cluster
generation, ownership operation, and revision with the plan's. Compile-fail fixtures pin the forbidden
constructions and role coercions.

**The demo registry delivery and application clients use the resolved-endpoint boundary.** Its finalized
registry plan selects proxy delivery, so generated registry configuration disables redirects to the cluster-only S3 store.
The cluster backend removes host publication from Kind/nvkind rendering, creates one owned relay on the
cluster container network, lets the container runtime assign its loopback host ports, and is the only producer
of authenticated resolved exposures. The worked demo carries those values lexically to store initialization,
registry deployment and image push, web readiness, and host-resident accelerator ingress; none reconstructs
an endpoint from a number.

**Three bindings are weaker than this page's target contract.**

- The demo's blob-route observation carries runtime information only in its status and in whether a
  `Location` was issued. `parseBlobRouteAnswer` copies the service, port, runtime identity, and revision
  from the plan, so the identity comparisons in settlement always pass, and nothing in the registry's
  answer identifies the registry, store, plan, or revision (see [Runtime admission](#runtime-admission)).
- The demo renders the registry's S3 `regionendpoint` from `objectStoreClusterEndpoint`, a second mint of
  the same literal the plan's store endpoint is minted from, not from `registryPlanStore`. The plan and the
  rendered registry configuration therefore agree by convention only.
- Core refuses only a zero revision and does not generate revisions; the demo builds every registry plan at
  revision `1`. A replacement plan at the same revision is not distinguished from its predecessor.

The [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns the core side of all three gaps: an observation producer that takes the dialled exposure from a fresh
relay inspection and the status and `Location` from the probe's answer, a store-address renderer that reads
`registryPlanStore`, and the revision rule. The
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the demo's adoption of the first two.

The [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns the generic reachability/delivery algebra, the finalized registry plan, and the blob-route observation
that `settleBlobRoute` consumes, which is the route proof an image push requires. The demo's `/v2/`
readiness witness (`ObservedReady` over `RegistryServing`) only orders the route probe after the registry
answers; it is not evidence that the route works. The
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the demo renderer, adoption, and live
proof.

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
`endpointScope` read it. `clusterOnlyEndpoint` is the only mint from text; host-local and VM-local
endpoints exist only inside an exposure (see [Exposure identity](#exposure-identity)). The text mint strips
surrounding whitespace and refuses empty, whitespace-bearing, scheme-bearing (`://`), and path-bearing
(`/`) text with `InvalidEndpointAuthority`. It does not parse a host or a port: `object-store`, `a:b:c`,
and `svc:99999` are all admitted, so a consumer that needs a valid port holds a `Port` rather than relying
on the authority text. Code must not infer scope by searching for `.svc`, `localhost`, or an IP
substring. A client spelling of `localhost` is also not proof that the listener is loopback-only.

`NetworkClient` is indexed by the scope it dials *from*, with one value per scope:
`hostLocalClient`, `vmLocalClient`, and `clusterOnlyClient`. `clientScope` reads it back.

For the worked demo, the pure cluster renderer declares registry, web, accelerator where applicable, and
S3 store as semantic services with stable cluster-internal targets. It emits no host-side port number and no
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
is the term-level view of the same relation for rendering and diagnostics. It is written separately, not
derived from the GADT: `RegistryPlanSpec` pins the agreement by checking every scope pair against the
four constructors' pairs, so adding a constructor requires changing both the function and that test.

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
scope. `Exposure` is opaque and carries five indices — its network scope, then the nominal lifecycle
scope, plan, cluster, and service — so a value minted for one plan or cluster
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

Therefore a host Docker client cannot be paired with redirect delivery to the cluster-only S3 store.

## The finalized registry plan

`RegistryPlan` is opaque, indexed by client scope, store scope, and the nominal lifecycle scope, plan,
cluster and service indices. It is reachable only through a topology-specific constructor, which pairs
one exposure with one caller-supplied store endpoint and fixes the delivery from the topology, so no caller
can re-pair them after construction or choose a delivery beside them. The store endpoint itself carries no
plan, cluster, or service index: the constructor accepts any `Endpoint 'ClusterOnly` the caller mints, and
nothing ties it to the exposure beyond being passed to the same constructor.

| Constructor | Topology | Delivery it fixes |
|---|---|---|
| `hostServedRegistryPlan` | a registry published on the host or VM loopback, blobs in a cluster-only store | `proxyThroughRegistry`, by construction |
| `inClusterRegistryPlan` | clients inside the cluster | `redirectToStore`, from the witness the caller supplies |

Both refuse a zero revision with `InvalidRegistryRevision`. Core enforces only that the revision is
positive; it does not generate revisions, so a fresh revision for each replacement plan is the caller's
obligation. `registryPlanClient`, `registryPlanExposure`, `registryPlanEndpoint`, `registryPlanStore`,
`registryPlanDelivery`, and `registryPlanRevision` read the finalized value. There is no independent
redirect boolean, no raw store-authority field, and no post-construction setter.

## Rendering rule

`renderStorageRedirect` is total over the finalized plan and takes the delivery as its only input:

| Delivery strategy | Rendered `storage.redirect` stanza |
|---|---|
| `ProxyBlobs` | `redirect:` / `disable: true` |
| `RedirectBlobs` | nothing — Distribution's own redirecting default stands |

For the demo topology the storage section reads as follows, abridged: the demo's `registryConfigYaml`
also renders a `cache` line before `redirect`, and `region`, `bucket`, `forcepathstyle`, and `secure`
under `s3`.

```yaml
storage:
  redirect:
    disable: true
  s3:
    regionendpoint: http://object-store.default.svc:9000
```

The boolean is serialized output, not a DSL choice: the redirect stanza is rendered from the plan's
delivery, so it cannot disagree with the plan's scopes. The demo's `regionendpoint` line is rendered from
`objectStoreClusterEndpoint`, which mints the same literal as the plan's store endpoint but is not read
from the plan; see [Current Status](#current-status).

## Runtime admission

Types prove the declared topology is coherent; a runtime observation checks the deployed blob route
before image push. The target contract is that, before image push, the interpreter verifies:

1. the exact client can reach the registry exposure;
2. the registry workload can reach the exact object-store endpoint and bucket;
3. a probe blob written through the registry can be queried through the registry without an
   out-of-scope redirect;
4. the response identifies the expected registry, store, plan, and deployment revision.

The demo meets the first three and not the fourth. Its probe dials the resolved exposure, uploads a canary
blob through the registry (which succeeds only if the registry can write to its store), and then issues a
non-following blob `HEAD`. It reads two facts from the answer: the HTTP status, and whether a `Location`
was issued. `parseBlobRouteAnswer` builds the `BlobRouteObservation` from those two facts and from fields
copied from the plan: the service, `Port`, and runtime identity triple from `registryPlanExposure`, the
revision from `registryPlanRevision`, and, for any `Location`, the scope of `registryPlanStore`, by
assumption rather than by resolving the authority.

`settleBlobRoute` mints a `ReadyBlobRoute` from an observation and refuses, in order: an
`ApiVersionProbe` rather than a `BlobHeadProbe` is `BlobRouteNotABlobProbe`, because a bare `GET /v2/`
proves only that the registry HTTP process is serving; a revision other than the plan's is
`BlobRouteStaleRevision`; and a different service, runtime identity, port, or delivery outcome is a
`BlobRouteMismatch`. A redirect is acceptable only for a plan whose delivery is `RedirectBlobs`, and only
to the planned authority in the planned scope; a proxying plan needs a `2xx` status and no `Location`.
Against the demo's observation the service, identity, port, and revision comparisons always pass, because
both sides come from the plan; the comparisons that carry runtime information are the status and the
presence of a `Location`.

`readyBlobRouteRevision` reads the settled revision back. The witness holds only that revision; its type
indices name the client and store scopes, the lifecycle scope, plan, cluster, and service, not the store
endpoint. The revision is compared once, at settlement, and the consumer does not re-check it.

The demo's `pushImageBlob` takes the `ReadyBlobRoute` as an argument, so a push cannot be written without a
settled witness carrying the same type indices; it does not read the witness's value. The pushed image
reference is a plain string the push step builds from `registryEndpoint` of the same plan, so the binding
between the proved route and the pushed endpoint is held by that step's code, not by a type.

The probe sequence is rendered by four additive Lift leaves with fixed argv: upload-session `POST`,
octet-stream `PATCH`, digest-completing `PUT`, and non-following blob `HEAD`. Tests pin every argument,
including timeouts, headers, payload position, and status/redirect output. Authenticated descent and the
sanitized lifecycle route likewise delegate crossing argv to `foldLeaf`; no registry or route module owns a
competing provider renderer.

The demo's in-cluster registry is anonymous over HTTP, so this blob route carries no credential. The
separate Docker Hub credential that `HostBootstrap.Registry` forwards to nested image pulls is a different
boundary: its stdin-delivered Lift plan exists only for a container reached directly through one Incus,
Lima, or WSL2 VM, and every other lift shape runs without it. See
[registry credentials](../engineering/registry_credentials.md).

## Invalid states

These states have no public constructor:

- a host-local client plus a cluster-only backend plus redirect delivery;
- endpoint text substituted across host/VM/cluster scopes;
- a raw redirect boolean that contradicts the delivery strategy;
- a `ReadyBlobRoute` minted other than by `settleBlobRoute`, or spent where a different scope, plan,
  cluster, or service index is required.

These states are constructible and refused at runtime by `settleBlobRoute`:

- readiness based only on `/v2/`: an `ApiVersionProbe` observation is publicly constructible and is
  refused with `BlobRouteNotABlobProbe`;
- an observation at a revision other than the plan's, refused with `BlobRouteStaleRevision`;
- a proxying plan whose registry issued a `Location`, refused with `BlobRouteMismatch`.

These states are not excluded:

- a registry exposure paired with a store endpoint minted for a different deployment, because the plan
  constructor accepts any cluster-only endpoint (see [The finalized registry plan](#the-finalized-registry-plan));
- a witness reused after a store or route replacement that keeps the revision, because the witness carries
  only the revision.

## Validation

These rules are pinned by:

- `RegistryPlanSpec`: port admission; every scope pair against `reachableFrom`; endpoint scope, path,
  empty, and whitespace refusals; runtime-identity retention on a resolved exposure; the host-served plan's
  proxy delivery and rendered `redirect: disable: true`, the in-cluster plan's empty rendering, and that
  delivery alone determines the rendering; the zero-revision refusal; and every `settleBlobRoute` outcome —
  a `/v2/` observation, a proxying plan that answers an illegal `307` or an error, a replacement revision, a
  redirect to the wrong target, a redirecting plan that serves the blob itself, and a different port,
  service, relay, generation, or operation;
- `CompileFailSpec` fixtures for the forbidden constructions: `HostLocalClusterRedirect`,
  `EndpointScopeSubstitution`, `ConstructRawHostEndpoint`, `ConstructRawLocalExposure`,
  `ForgeResolvedExposure`, `ImportClusterExposureInternal`, `CoerceExposureAuthorityRoles`,
  `RawRegistryPlan`, and `ForgeReadyBlobRoute`;
- `RegistrySpec`: the exact argv of the four blob-probe Lift leaves;
- the worked demo's live gate: its push step settles the blob route through the resolved relay exposure
  before every push, and `assertRegistrySurvivesRestart` reads the pushed image's tag list through the
  registry NodePort on a cluster node, deletes the registry pod, and reads it again. The
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) records the runs.

Not covered: a pull of the pushed image through the relay exposure (the web workload runs the image loaded
into the Kind nodes), a repeated push as a separate case, and a registry answer that identifies the
registry, store, plan, or revision (see [Runtime admission](#runtime-admission)).

See [in-cluster registry](../engineering/in_cluster_registry.md) for the demo topology and
[composition methodology](composition_methodology.md) for integration into the single project plan.
