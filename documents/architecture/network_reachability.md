# Network Reachability and Registry Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../engineering/in_cluster_registry.md](../engineering/in_cluster_registry.md), [composition_methodology.md](composition_methodology.md), [../engineering/derived_project_standards.md](../engineering/derived_project_standards.md)

> **Purpose**: Define the typed endpoint-reachability and blob-delivery doctrine that prevents a
> registry client from being redirected to an endpoint outside its network scope.

## TL;DR

An endpoint is not `Text`; it carries the network scope from which it is reachable. A registry plan
jointly binds its client, published exposure, object-store endpoint, and blob-delivery strategy.
Redirect delivery is constructible only with proof that the client can reach the backing endpoint.
When a host-local Docker client reaches a NodePort registry backed by cluster-only MinIO, the only legal
delivery strategy is `ProxyThroughRegistry`, and the renderer necessarily emits
`storage.redirect.disable: true`.

The implementation is currently weaker: the demo independently renders a NodePort, the internal
`minio.default.svc` endpoint, and an S3 stanza with Distribution's default redirects enabled. A repeated
blob `HEAD` receives `307` to the cluster-only MinIO name, which the host Docker client cannot resolve.
The owning development-plan sprints remain open until the illegal combination is unrepresentable and
the live route is validated.

## Current Status

The target types and constructors in this document are normative but not yet implemented.
`hostbootstrap-demo` currently assembles registry and MinIO manifests from raw strings in
`demo/src/HostBootstrapDemo/Commands.hs`. The current failure is not an S3 credential, image-size,
resource-limit, or nvkind defect: Distribution redirects an external client's blob request to
`http://minio.default.svc:9000`, crossing from host-local scope into cluster-only scope.

Phase 14 owns the generic reachability/delivery algebra. Phase 13 owns the demo's finalized registry
plan, renderer, and live proof. Phase 9's opaque readiness and operation-precondition work supplies the
identity-bound runtime observation consumed by the push operation.

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
publishing mechanism before minting it. `localhost:30500` supplied as text cannot claim
`RegistryExposure HostLocal registryId`; the kind mapping must be proven to bind the intended interface
in the intended provider/host namespace.

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
- a live host-client → NodePort registry → cluster-only MinIO push, repeated push, pull, registry-pod
  restart, and tag lookup;
- assertions that proxy mode exposes no cluster-only MinIO URL to the client.

See [in-cluster registry](../engineering/in_cluster_registry.md) for the demo topology and
[composition methodology](composition_methodology.md) for integration into the single project plan.
