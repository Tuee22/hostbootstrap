# Network Reachability and Registry Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../engineering/in_cluster_registry.md](../engineering/in_cluster_registry.md), [composition_methodology.md](composition_methodology.md), [../engineering/derived_project_standards.md](../engineering/derived_project_standards.md)

> **Purpose**: Define the typed endpoint-reachability and blob-delivery doctrine that prevents a
> registry client from being redirected to an endpoint outside its network scope.

## TL;DR

An endpoint is not `Text`; it carries the network scope from which it is reachable. A registry plan
jointly binds its client, published exposure, object-store endpoint, and blob-delivery strategy.
Local publication is a runtime-owned resource: configuration names a semantic service and stable
cluster-internal target, the container runtime atomically assigns a loopback port to an identity-bound relay,
and authenticated inspection of that exact relay produces the endpoint clients consume. The selected port is
never a Dhall value or a canonical Kind/nvkind input.
Redirect delivery is constructible only with proof that the client can reach the backing endpoint.
When a host-local Docker client reaches a NodePort registry backed by cluster-only MinIO, the only legal
delivery strategy is `ProxyThroughRegistry`, and the renderer necessarily emits
`storage.redirect.disable: true`.

## Current Status

**The generic algebra and resolved-endpoint boundary are implemented** (`HostBootstrap.Network`,
`HostBootstrap.RegistryPlan`). The scope is a
type index, `Reachability` is a closed GADT with no host-local→cluster-only constructor, the redirecting
`BlobDelivery` constructor takes that witness, `RegistryPlan` is opaque behind topology-specific
constructors, and the `storage.redirect` stanza is derived from the delivery rather than chosen beside it.
Local `Exposure`, `RegistryPlan`, and `ReadyBlobRoute` retain nominal lifecycle-scope, plan, cluster, and
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

Names differ slightly between this document and the implementation: the shipped scope kind is
`NetworkScope = HostLocal | VmLocal | ClusterOnly` (no `Public` scope exists yet, and the
provider-guest scope is spelled `VmLocal`), and the delivery constructors are `proxyThroughRegistry`
and `redirectToStore`. The invariants below are the ones enforced.

## Reachability Kinds

Reachability is a closed kind, not a hostname convention:

```haskell
data Reachability = ClusterOnly | ProviderLocal | HostLocal | Public
```

An endpoint carries both its service identity and reachability:

```haskell
data Endpoint (reach :: Reachability) service where
    ClusterEndpoint :: ClusterDnsName service -> Port -> Endpoint ClusterOnly service
    ProviderEndpoint :: ProviderAddress provider service -> Port -> Endpoint ProviderLocal service
    HostEndpoint :: HostAddress service -> Port -> Endpoint HostLocal service
    PublicEndpoint :: VerifiedPublicOrigin service -> Endpoint Public service
```

Constructors validate syntax and topology ownership. Code must not infer scope by searching for
`.svc`, `localhost`, or an IP substring. A client spelling of `localhost` is also not proof that the
listener is loopback-only.

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

## Client and Exposure Identity

The plan records where the registry client runs and how the registry is exposed:

```haskell
data RegistryClient (reach :: Reachability) where
    InClusterClient :: RegistryClient ClusterOnly
    ProviderDockerClient :: RegistryClient ProviderLocal
    HostDockerClient :: RegistryClient HostLocal
    PublicRegistryClient :: RegistryClient Public

data RegistryExposure (reach :: Reachability) registryId
```

`RegistryExposure` is opaque. A backend/topology-specific constructor verifies the actual listener and
publishing mechanism before minting it. A `localhost` URL supplied as text cannot claim
`RegistryExposure HostLocal registryId`; the exact relay identity and runtime-inspected mapping must prove the
intended loopback interface in the intended provider/host namespace.

The selected number lives only in an opaque value such as:

```haskell
data ResolvedExposure scope planId clusterId service
```

Its hidden constructor binds the service, protocol, selected loopback port, internal target, relay/container
identity, cluster generation, and ownership operation. It is carried with the cluster dependency package and
freshly re-inspected when opened. It is never serialized back into Dhall, cached as a conventional endpoint,
or recreated from a number. Stable Kubernetes Service/NodePort values are internal targets and do not imply a
same-number host publication.

Scanning for a free port and then closing the probe is not supported: the gap before the real bind admits a
race. The same rule excludes treating a launcher-specific `hostPort: 0` expansion as allocation when that
launcher first selects and releases a candidate. The component that retains the binding must choose it.

## Blob Delivery

Blob delivery is a relation between client and backend reachability:

```haskell
data ReachableFrom clientReach backendReach where
    SameReachability :: ReachableFrom reach reach
    PublicFromAnyScope :: ReachableFrom clientReach Public

data BlobDelivery backendReach clientReach where
    ProxyThroughRegistry :: BlobDelivery backendReach clientReach
    RedirectToBackend ::
        ReachableFrom clientReach backendReach ->
        BlobDelivery backendReach clientReach
```

There is deliberately no constructor for `ReachableFrom HostLocal ClusterOnly`. Therefore a host Docker
client cannot be paired with redirect delivery to cluster-only MinIO. A future provider may add a
reachability proof only when it can verify a real route; it must not add a coercion or string-based
escape hatch.

## Finalized Registry Plan

The public API exposes topology-specific smart constructors, not the existential constructor:

```haskell
data RegistryPlan scope specDigest planId registryId

inClusterRegistry ::
    RegistryClient ClusterOnly ->
    RegistryExposure ClusterOnly registryId ->
    ObjectStore scope planId ClusterOnly storeId ->
    RegistryPlan scope specDigest planId registryId

hostPublishedRegistry ::
    RegistryClient HostLocal ->
    RegistryExposure HostLocal registryId ->
    ObjectStore scope planId ClusterOnly storeId ->
    RegistryPlan scope specDigest planId registryId
```

The finalized value jointly binds lifecycle scope, plan and resource identities, client reachability,
verified exposure, backing endpoint, delivery, credential authority, anonymous-development policy, and
the exact workload projections. `hostPublishedRegistry` selects `ProxyThroughRegistry` by construction.
There is no independent `redirectDisabled :: Bool`, raw `regionEndpoint :: Text`, or
post-construction setter.

## Rendering Rule

The renderer is total over the finalized plan:

```text
ProxyThroughRegistry -> storage.redirect.disable = true
RedirectToBackend _  -> storage.redirect.disable = false
```

For the demo topology it renders:

```yaml
storage:
  redirect:
    disable: true
  s3:
    regionendpoint: http://minio.default.svc:9000
```

The boolean is serialized output, not a DSL choice. Registry exposure and the MinIO endpoint are
rendered from the same plan, so separately supplied manifests cannot disagree about scope or identity.

## Runtime Admission

Types prove the declared topology is coherent; runtime observations prove the deployed topology matches
the declaration. Before image push, the interpreter verifies:

1. the exact client can reach the registry exposure;
2. the registry workload can reach the exact object-store endpoint and bucket;
3. a probe blob written through the registry can be queried through the registry without an
   out-of-scope redirect;
4. the response identifies the expected registry, store, plan, and deployment revision.

The successful observation mints:

```haskell
ReadyBlobRoute scope planId registryId storeId clientReach revision
```

The prepared push adapter requires that exact readiness value through the plan-owned precondition set.
A bare `GET /v2/` proves only that the registry HTTP process is serving; it does not prove the blob
route. A `307` is acceptable only for a plan carrying `RedirectToBackend` and the matching reachability
proof.

The probe sequence is rendered by four additive Lift leaves with fixed argv: upload-session `POST`,
octet-stream `PATCH`, digest-completing `PUT`, and non-following blob `HEAD`. Tests pin every argument,
including timeouts, headers, payload position, and status/redirect output. Registry authentication remains
higher policy: `HostBootstrap.Registry` consumes the generic Lift and its quoting rule. Authenticated
descent and the sanitized lifecycle route likewise delegate crossing argv to `foldLeaf`; no registry or
route module owns a competing provider renderer.

## Invalid States

These states have no public constructor:

- external or host-local client plus cluster-only backend plus redirects;
- endpoint text substituted across host/provider/cluster scopes;
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
- a live host-client → resolved relay exposure → internal NodePort registry → cluster-only MinIO push,
  repeated push, pull, registry-pod
  restart, and tag lookup;
- assertions that proxy mode exposes no cluster-only MinIO URL to the client.

See [in-cluster registry](../engineering/in_cluster_registry.md) for the demo topology and
[composition methodology](composition_methodology.md) for integration into the single project plan.
