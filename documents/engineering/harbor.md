# Harbor (downstream guidance)

**Status**: Supporting reference
**Supersedes**: the prior downstream-push reference
**Referenced by**: [../README.md](../README.md), [derived_project_standards.md](derived_project_standards.md), [build_release.md](build_release.md)

> **Purpose**: Document the convention for a downstream project pushing its own arch-explicit image,
> and make clear that hostbootstrap core never pushes project images.

The hostbootstrap core **does not push your project image.** It builds the project
container `FROM` the base tag (the code-check gate) and materializes the project
binary, then stops. Whether and how the project container reaches a registry is the
**downstream project's** job, not the core's. This page is convention, not
enforcement: the core has no push command for project images and no Harbor
configuration of its own.

A project that wants its container in a registry contributes its own chain steps
that push it as part of the project's deploy. The `hostbootstrap-demo` consumer
does exactly this: its `deploy-harbor` and `push-image` steps stand up an
in-cluster Harbor and push the project image during `project up`.

## Recommended convention: arch-explicit tags only

When a downstream project does push, push **arch-explicit single-arch tags** and
nothing else. The substrate is always known at push time, so the correct tag is
always nameable — there is never a reason to assemble a cross-arch manifest list.

`<project>-<substrate>-<arch>` is the recommended tag shape.

> **WRONG**
>
> ```sh
> docker buildx build --platform linux/amd64,linux/arm64 \
>   --tag harbor.example/app:latest --push .
> ```
>
> A multi-platform `buildx` push produces a manifest list — exactly the
> cross-arch indirection this convention avoids. It also pushes an arch you did
> not build on this host (via emulation), which the design forbids.
>
> **RIGHT**
>
> ```sh
> docker build --tag harbor.example/app-linux-cpu-amd64 .
> docker push harbor.example/app-linux-cpu-amd64
> ```
>
> Single-arch, host-native, with the substrate and arch named explicitly.

## No orphans

When the project pushes a new arch-explicit tag, it should delete any prior tag
*it owns* that now points at a superseded digest. Reclaiming the untagged digest
itself depends on the Harbor instance's GC policy. Keeping this discipline in the
project (rather than the tool) means the project owns its registry namespace
end-to-end.

## Base-image publication is separate

The four `basecontainer-<flavor>-<arch>` base tags are **not** project images and
are **not** covered here. hostbootstrap publishes those itself via
`hostbootstrap base build-and-push`; see [build_release.md](build_release.md)
and [base_image.md](base_image.md). A project never re-pushes the large base
image — it pulls the base from Docker Hub and pushes only its own thin
layer(s).

The `hostbootstrap-demo` consumer (`demo/`) drives this convention end-to-end. Its
`deploy-harbor` and `push-image` steps belong to the container frame of
`demoChain :: ProjectConfig -> [Step]`, the demo's contributed chain, and `project
up` interprets them as it descends into that frame. `deploy-harbor` installs the
in-cluster Harbor with `helm upgrade --install harbor harbor/harbor --version
1.18.3`, **overriding every Harbor component image to the dual-arch
`ghcr.io/octohelm/harbor/*` mirror** (see the next section), exposes it as a
NodePort on port 30500, and waits for all eight Harbor pods to be Ready.
`push-image` loads the project image into the kind nodes, logs in to the registry
at `localhost:30500`, tags the image, and pushes it to
`localhost:30500/library/hostbootstrap-demo:demo`. The push runs as part of the
live persistent stack that `project up` stands up.

## Dual-arch Harbor component images

The in-cluster Harbor's own component images must match the architecture of the
kind node they run on — the same host-native, no-emulation discipline this page
applies to project image *pushes*, applied now to the registry the demo *deploys*.

The upstream `goharbor/*` images (`harbor-core`, `harbor-db`, `redis-photon`,
`registry-photon`, `nginx-photon`, `harbor-portal`, `harbor-jobservice`,
`harbor-registryctl`, `trivy-adapter-photon`) are published as **amd64-only
single-arch manifests** — they carry no `linux/arm64` variant. On an `arm64` kind
node (the substrate when the VM runs on Apple Silicon) every Harbor pod then
crash-loops with `exec format error`, because the node runs an amd64 binary it
cannot execute. This is a substrate floor, not a resource limit: the kind node
reports `MemoryPressure False` while the pods crash.

The demo's `deploy-harbor` step therefore retargets each component's
`image.repository` / `image.tag` to the community **`ghcr.io/octohelm/harbor/*`**
mirror at the chart-matched tag `v2.14.0`, which publishes both `linux/amd64` and
`linux/arm64` for every component. The chart is pinned to `1.18.3` so its templates
stay in lockstep with the `v2.14.0` images. Harbor then runs natively on whatever
architecture the VM is — `arm64` on Apple Silicon, `amd64` on Linux — with no
emulation and no cross-arch indirection.

> **WRONG**
>
> ```sh
> helm upgrade --install harbor harbor/harbor --set expose.type=nodePort
> ```
>
> The default chart pulls `goharbor/*`, which is amd64-only. On an `arm64` kind
> node the pods crash-loop with `exec format error`, and `--wait` times out on
> `harbor-core not ready`. Pre-pulling and `kind load`-ing the same images does
> **not** help: the host pull on Apple Silicon still resolves to the only
> (amd64) manifest, so the loaded image is still the wrong architecture. `kind
> load` fixes registry rate limits and network resolution, not architecture.
>
> **RIGHT**
>
> ```sh
> helm upgrade --install harbor harbor/harbor --version 1.18.3 \
>   --set core.image.repository=ghcr.io/octohelm/harbor/harbor-core \
>   --set core.image.tag=v2.14.0 \
>   # …and the same repository/tag override for every other component…
> ```
>
> Dual-arch (`linux/amd64` + `linux/arm64`) images at a tag matched to the pinned
> chart, so the kubelet selects the node-native variant and Harbor runs without
> emulation on either substrate.

`hostbootstrap-core` does not own this override — it is a property of the demo's
contributed chain step (`deployHarborAction` in
`demo/src/HostBootstrapDemo/Commands.hs`), consistent with the core never owning
Harbor configuration. A derived project that deploys Harbor adopts the same
dual-arch override in its own `deploy-harbor` step.

## See also

* [derived_project_standards.md](derived_project_standards.md) — the five
  rules every derived project follows, including the build-time code-check
  and warm-store cache-hit contract that govern what gets compiled into the
  thin layer this page is about.
