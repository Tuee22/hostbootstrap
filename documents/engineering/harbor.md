# Harbor (downstream guidance)

**Status**: Supporting reference
**Supersedes**: the execution-model split (container vs host-binary/host-daemon ownership of the push)
**Referenced by**: [../README.md](../README.md), [derived_project_standards.md](derived_project_standards.md), [build_release.md](build_release.md)

> **Purpose**: Document the convention for a downstream project pushing its own arch-explicit image,
> and make clear that hostbootstrap never pushes project images.

hostbootstrap **does not push your project image.** It builds the project
container `FROM` the base tag (the code-check gate) and materializes the project
binary at `./.build/<project>`, then stops. Whether and how the project container
reaches a registry is the **downstream project's** job, not the tool's. This page
is convention, not enforcement: hostbootstrap has no `push` command for project
images and no Harbor configuration of its own.

If the project wants its container in Harbor, the project's own build/CI step (or
a subcommand on the project binary) pushes it as part of its own lifecycle.

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

## See also

* [derived_project_standards.md](derived_project_standards.md) — the five
  rules every derived project follows, including the build-time code-check
  and warm-store cache-hit contract that govern what gets compiled into the
  thin layer this page is about.
