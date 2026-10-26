# In-cluster registry

**Status**: Supporting reference
**Supersedes**: harbor.md
**Referenced by**: [../README.md](../README.md), [../architecture/network_reachability.md](../architecture/network_reachability.md), [derived_project_standards.md](derived_project_standards.md), [cluster_lifecycle.md](cluster_lifecycle.md), [registry_credentials.md](registry_credentials.md), [../languages/cluster_tooling.md](../languages/cluster_tooling.md)

> **Purpose**: Document the in-cluster OCI registry a downstream project stands up to push its own
> arch-explicit image, describe the legal proxy route, and explain how the downstream
> project consumes core's reachability-safe registry plan without transferring image ownership
> to core.

## Current Status

The demo uses a finalized proxy-delivery plan for a host client and a cluster-only S3 store. It renders
`storage.redirect.disable: true`, so repeated blob requests stay on the reachable registry endpoint rather
than redirecting the host client to `object-store.default.svc:9000`.

The contract is the typed plan in
[network reachability](../architecture/network_reachability.md): core owns the generic endpoint,
client, delivery, and readiness vocabulary; the demo owns its registry resources, project-image
operation, and topology-specific plan. For this topology, proxy delivery is selected by construction
and rendering necessarily emits `storage.redirect.disable: true`. The
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns the generic proof-gated plan; the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)
owns its renderer, adoption, and live push and persistence evidence.

Two demo bindings are weaker than that plan contract; the canonical statement is in
[network reachability](../architecture/network_reachability.md#current-status). The registry's S3
`regionendpoint` is rendered from `objectStoreClusterEndpoint`, a second mint of the same literal the plan's
store endpoint is minted from, not read from the plan, so the plan and the rendered registry configuration
agree by convention only. The blob-route observation carries runtime information only in the probe's HTTP
status and in whether a `Location` was issued: `parseBlobRouteAnswer` copies the service, port, runtime
identity, and revision from the plan, so nothing in the registry's answer identifies the registry, store,
plan, or revision. The composition-and-network-algebra phase owns the core side of both gaps and the
worked-demo phase owns their adoption in the demo.

The demo's live gate does not pull the pushed image back through the resolved registry exposure, before or
after a registry pod restart, and has no separate repeated-push case; its persistence case reads only the tag
list over the internal NodePort (see [Validation](#validation)). The
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that pull-after-restart proof.

The hostbootstrap core **does not build or push your project image.** The thin Python bootstrapper
materializes the host-native project binary. Once that binary is running, a project-supplied build-image
chain action may build a project container `FROM` the base tag and run its code-check gate; core only
interprets the contributed action. Whether and how the resulting image reaches a registry is the
**downstream project's** job. Core has no project-image push command. Its responsibility is
generic enforcement: it supplies reachability-safe planning and readiness types, while the consumer
supplies and interprets its own concrete registry resources and push operation.

A project that wants its container in a registry contributes its own chain steps
that push it as part of the project's deploy. The `hostbootstrap-demo` consumer
registers `deploy-registry` and `push-image` for that purpose. Its rendered
configuration derives the legal proxy delivery strategy from the exact plan; live acceptance remains
the proof of the complete blob route.

## The registry: single-binary `registry:2`

The demo's in-cluster registry is the **single-binary CNCF `distribution`
(`registry:2`) OCI registry** — one Deployment plus a NodePort Service, not a
multi-pod stack. `registry:2` publishes a **multi-arch manifest**, so the same
upstream image runs natively on `amd64` and `arm64` kind nodes with no
per-component image override and no emulation. It runs **anonymous over HTTP**. The target client endpoint is
projected only from the exact runtime-owned loopback relay; there is no registry host port in Dhall or canonical
Kind/nvkind config. Relay inspection proves the selected loopback mapping before a client receives it. There
is no registry authentication or TLS boundary.

The `hostbootstrap-demo` consumer (`demo/`) drives this end-to-end. Its
`deploy-registry` and `push-image` steps belong to the container frame of `demoChainFor`, the demo's
contributed chain (its signature is spelled in [run models](../architecture/run_models.md)), and `project
up` interprets them as it descends into that frame. `deploy-registry` applies a
single Deployment + internal NodePort Service with `kubectl` and waits for the
Deployment to be Ready; the registry pod **pulls** `registry:2` itself
(`imagePullPolicy: IfNotPresent`), so containerd on the node selects the node
platform from the multi-arch manifest. It is **not** `kind load`-ed: `kind load
docker-image` (a `docker save` + `ctr import --all-platforms`) cannot import a
multi-arch image (it fails `content digest … not found`).
`push-image` loads the project image into the kind nodes, tags it, and pushes it through the exact resolved
registry exposure as `library/hostbootstrap-demo:demo` (the tag names neither substrate nor arch; see
[the convention](#recommended-convention-arch-explicit-tags-only) for why the demo is exempt). The push is registered in the
live stack that `project up` stands up, but registration and `/v2/` readiness are
not proof that the blob route works.

`hostbootstrap-core` does not own the registry resource — it is a property of the demo's
contributed chain step (`deployRegistryAction` in
`demo/src/HostBootstrapDemo/Commands.hs`). A derived project that deploys a registry contributes its
own resource step, and the API requires it to construct that step from core's opaque registry plan rather
than independently choosing endpoint strings and redirect flags: `deployRegistryAction` and `pushImageAction`
both derive their plan from the resolved exposure through `registryPlanFromExposure`.

## Persistent storage: S3-backed

The `registry:2` pod is stateless, and its storage is externalized to an in-cluster
**VersityGW** bucket rather than the pod's ephemeral filesystem. This is the demo's
contributed `deploy-object-store` chain step (`deployObjectStoreAction`), ordered **before**
`deploy-registry`: a `ghcr.io/versity/versitygw:v1.7.0` Deployment + an `object-store-data` PVC (bound to kind's
default `local-path` StorageClass) + an `object-store-credentials` Secret, followed by
`mc mb --ignore-existing` to create the `registry` bucket. The bucket-init runs from
the container frame reusing the base image's `mc` client through the exact resolved store exposure. A client
spelling of localhost is not itself listener or ownership proof; the relay inspection supplies both. The registry's storage
stanza is supplied by a mounted `registry-config` ConfigMap declaring only the `s3`
driver pointing at `object-store.default.svc:9000` (its `regionendpoint` is rendered from
`objectStoreClusterEndpoint`, not from the registry plan; see [Current Status](#current-status)); the two S3
credentials are layered in by
env from the Secret. Those Secret values are currently hardcoded source constants
(`hostbootstrap` / `hostbootstrap-demo-secret`) in
`demo/src/HostBootstrapDemo/Commands.hs`; Kubernetes Secret encoding is not secret generation or
at-rest encryption. This is suitable only for the worked local demo. (Env-only S3 config does not work:
stock `registry:2` ships a
default `config.yml` with a `filesystem` driver, so `REGISTRY_STORAGE_S3_*` env alone
yields two drivers and the registry refuses to start — hence the ConfigMap replaces
the whole config file.) The `deploy-object-store` step is ordered first because the s3
driver requires the bucket to pre-exist.

Distribution's default storage redirect is illegal for the host-client/cluster-only-store topology. The
registry DSL does not expose that setting as a boolean: `proxyThroughRegistry` is the only constructible
delivery strategy for this topology, and the renderer derives `storage.redirect.disable: true`. See
[network reachability](../architecture/network_reachability.md) for the type-level rule.

The worked local demo uses the explicit development credentials described above. These constants do not
establish per-run secret derivation or a production authentication policy. Exact loopback exposure is owned
and verified by the cluster backend; spelling a client address as `localhost` alone is not that proof.

**Why.** With the default ephemeral filesystem driver a registry pod restart (crash,
eviction, node reboot) loses every pushed blob — `GET /v2/<repo>/tags/list` 404s.
S3-backed, the restarted pod can re-read the blobs from the store and the pushed tag
survives. The `registry-persistence` harness case checks this: it reads the pushed image's tag list over
the internal registry NodePort, deletes the registry pod, waits for the new rollout, and reads the tag list
again. The S3 store PVC lives on the kind node's `local-path` volume, so durability spans **registry pod**
restarts only. Both `project down` and `project destroy` delete the kind cluster, and the store PVC with it,
so the registry contents do not survive either (the in-VM cluster is ephemeral by design; the registry's
durable state lives inside the cluster, and the demo mirrors none of it back to the
host — see [../architecture/durable_state.md](../architecture/durable_state.md)).

**The design trade.** The registry and store use separate single-binary,
multi-architecture images. The stack includes a stateful VersityGW Deployment,
a PVC, a Secret, and a ConfigMap, which provides durability across registry pod
restarts while remaining portable across the supported node architectures.

## Recommended convention: arch-explicit tags only

When a downstream project does push, push **arch-explicit single-arch tags** and
nothing else. The substrate is always known at push time, so the correct tag is
always nameable — there is never a reason to assemble a cross-arch manifest list.

The canonical reference form is `<registry>/<project>:<substrate>-<arch>`: the repository names the
project, and the tag names the substrate and architecture.

The worked demo is exempt. Its registry lives inside one single-architecture Kind cluster, is reached only
through that cluster's own exposure, and is deleted with the cluster by `project down` and
`project destroy`; no other substrate or architecture ever reads it, so its single tag
`library/hostbootstrap-demo:demo` cannot be resolved for the wrong architecture. The convention binds any
registry that outlives one cluster or is shared across substrates.

> **WRONG**
>
> ```sh
> docker buildx build --platform linux/amd64,linux/arm64 \
>   --tag registry.example/app:latest --push .
> ```
>
> A multi-platform `buildx` push produces a manifest list — exactly the
> cross-arch indirection this convention avoids. It also pushes an arch you did
> not build on this host (via emulation), which the design forbids.
>
> **RIGHT**
>
> ```sh
> docker build --tag registry.example/app:linux-cpu-amd64 .
> docker push registry.example/app:linux-cpu-amd64
> ```
>
> Single-arch, host-native, with the substrate and arch named explicitly.

## No orphans

When the project pushes to an arch-explicit tag it already owns, the tag moves to the new digest and the
previous digest becomes untagged. When the project retires a tag (for example a substrate it no longer
builds for), it deletes that tag. Reclaiming untagged digests depends on the registry's garbage collection
(`registry garbage-collect` for `distribution`). Keeping this discipline in the project (rather than the tool)
means the project owns its registry namespace end-to-end.

## Base-image publication is separate

The four `basecontainer-<flavor>-<arch>` base tags are **not** project images and
are **not** covered here. hostbootstrap publishes those itself via
`hostbootstrap base build-and-push`; see [build_release.md](build_release.md)
and [base_image.md](base_image.md). A project never re-pushes the large base
image — it pulls the base from Docker Hub and pushes only its own thin
layer(s).

## Validation

The registry topology is checked by:

1. `RegistryPlanSpec` and the `HostLocalClusterRedirect` and `RawRegistryPlan` compile-fail fixtures, which
   prove the illegal redirect topology and an independent raw redirect flag cannot be constructed and that
   the host-served plan renders `storage.redirect.disable: true` (the full list is in
   [network reachability](../architecture/network_reachability.md#validation));
2. the demo's `push-image` step, which takes `/v2/` readiness through the resolved registry exposure, then
   uploads a canary blob and issues a non-following blob `HEAD` from the pushing frame, and admits the route
   only for a `2xx` status with no `Location` (any redirect is refused) before it pushes the project image
   through the same exposure;
3. the `registry-persistence` case, which reads the pushed image's tag list over the internal registry
   NodePort, deletes the registry pod, and reads the tag list again after the new rollout.

A successful `GET /v2/` or Deployment Ready condition alone is not proof that the blob route works; the
canary-blob check above is the route check. It does not identify the registry, store, plan, or revision
that answered, because the observation's identity fields are copied from the plan (see
[Current Status](#current-status)). No case pulls the pushed image back through the resolved exposure, before or
after the registry pod restart, and no case pushes the same image twice (see [Current Status](#current-status)).
The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) records the live runs.

## See also

* [derived_project_standards.md](derived_project_standards.md) — the five
  rules every derived project follows, including the build-time code-check
  and the opportunistic warm-store cache rule that govern what gets compiled into the
  thin layer this page is about.
