# In-cluster registry

**Status**: Supporting reference
**Supersedes**: harbor.md
**Referenced by**: [../README.md](../README.md), [derived_project_standards.md](derived_project_standards.md), [build_release.md](build_release.md)

> **Purpose**: Document the in-cluster OCI registry a downstream project stands up to push its own
> arch-explicit image, and make clear that hostbootstrap core never pushes project images.

The hostbootstrap core **does not push your project image.** It builds the project
container `FROM` the base tag (the code-check gate) and materializes the project
binary, then stops. Whether and how the project container reaches a registry is the
**downstream project's** job, not the core's. This page is convention, not
enforcement: the core has no push command for project images and no registry
configuration of its own.

A project that wants its container in a registry contributes its own chain steps
that push it as part of the project's deploy. The `hostbootstrap-demo` consumer
does exactly this: its `deploy-registry` and `push-image` steps stand up an
in-cluster registry and push the project image during `project up`.

## The registry: single-binary `registry:2`

The demo's in-cluster registry is the **single-binary CNCF `distribution`
(`registry:2`) OCI registry** — one Deployment plus a NodePort Service, not a
multi-pod stack. `registry:2` publishes a **multi-arch manifest**, so the same
upstream image runs natively on `amd64` and `arm64` kind nodes with no
per-component image override and no emulation. It runs **anonymous over HTTP**: a
`localhost` NodePort is insecure-by-default in Docker, so a push needs no `docker
login` and no TLS.

The `hostbootstrap-demo` consumer (`demo/`) drives this end-to-end. Its
`deploy-registry` and `push-image` steps belong to the container frame of
`demoChain :: ProjectConfig -> [Step]`, the demo's contributed chain, and `project
up` interprets them as it descends into that frame. `deploy-registry` pre-loads
`registry:2` onto the kind nodes (`kind load`), applies a single Deployment +
NodePort-30500 Service with `kubectl`, and waits for the Deployment to be Ready.
`push-image` loads the project image into the kind nodes, tags it, and pushes it to
`localhost:30500/library/hostbootstrap-demo:demo`. The push runs as part of the
live persistent stack that `project up` stands up.

`hostbootstrap-core` does not own the registry — it is a property of the demo's
contributed chain step (`deployRegistryAction` in
`demo/src/HostBootstrapDemo/Commands.hs`), consistent with the core never owning
registry configuration. A derived project that deploys a registry contributes the
same single-binary `registry:2` step in its own chain.

## Recommended convention: arch-explicit tags only

When a downstream project does push, push **arch-explicit single-arch tags** and
nothing else. The substrate is always known at push time, so the correct tag is
always nameable — there is never a reason to assemble a cross-arch manifest list.

`<project>-<substrate>-<arch>` is the recommended tag shape.

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
> docker build --tag registry.example/app-linux-cpu-amd64 .
> docker push registry.example/app-linux-cpu-amd64
> ```
>
> Single-arch, host-native, with the substrate and arch named explicitly.

## No orphans

When the project pushes a new arch-explicit tag, it should delete any prior tag
*it owns* that now points at a superseded digest. Reclaiming the untagged digest
itself depends on the registry's garbage collection (`registry garbage-collect`
for `distribution`). Keeping this discipline in the project (rather than the tool)
means the project owns its registry namespace end-to-end.

## Base-image publication is separate

The four `basecontainer-<flavor>-<arch>` base tags are **not** project images and
are **not** covered here. hostbootstrap publishes those itself via
`hostbootstrap base build-and-push`; see [build_release.md](build_release.md)
and [base_image.md](base_image.md). A project never re-pushes the large base
image — it pulls the base from Docker Hub and pushes only its own thin
layer(s).

## See also

* [derived_project_standards.md](derived_project_standards.md) — the five
  rules every derived project follows, including the build-time code-check
  and warm-store cache-hit contract that govern what gets compiled into the
  thin layer this page is about.
