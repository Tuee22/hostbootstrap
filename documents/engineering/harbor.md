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
in-cluster Harbor with `helm upgrade --install harbor harbor/harbor`, exposes it as
a NodePort on port 30500, and waits for all eight Harbor pods to be Ready.
`push-image` loads the project image into the kind nodes, logs in to the registry
at `localhost:30500`, tags the image, and pushes it to
`localhost:30500/library/hostbootstrap-demo:demo`. The push runs as part of the
live persistent stack that `project up` stands up.

## See also

* [derived_project_standards.md](derived_project_standards.md) — the five
  rules every derived project follows, including the build-time code-check
  and warm-store cache-hit contract that govern what gets compiled into the
  thin layer this page is about.
