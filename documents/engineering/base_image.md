# Base image

**Status**: Authoritative source
**Supersedes**: the immutable-input and layered-freeze base-image doctrine
**Referenced by**: [../README.md](../README.md), [warm_store.md](warm_store.md),
[derived_project_standards.md](derived_project_standards.md), [build_release.md](build_release.md),
[code_check_doctrine.md](code_check_doctrine.md)

> **Purpose**: Define the four rolling native-architecture base tags, their tool/cache contents, and
> the build and publication rules.

## Tags and architecture

Four single-architecture rolling tags carry the shared toolchain:

```text
docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64
docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64
docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64
docker.io/tuee22/hostbootstrap:basecontainer-cuda-arm64
```

There are no manifest lists. Before any build, the CLI requires the requested architecture, detected
host architecture, and Docker-engine architecture to match. Buildx/emulation and cross-architecture
publication are rejected.

The maintainer `base` command selects an explicit CPU/CUDA flavor and architecture. A consuming project
separately maps its detected substrate to one published tag. The demo uses CPU for Apple Silicon,
Linux CPU, Windows CPU, and Windows GPU; it uses CUDA for Linux GPU. Windows accelerator workers remain
host-native and add no base flavor.

## Rolling input policy

A base rebuild intentionally discovers current/latest compatible upstream inputs. The CPU parent is the
rolling Ubuntu 24.04 tag; CUDA resolution selects the highest compatible
`cudnn-devel-ubuntu24.04` tag that publishes the requested native architecture. Go, Node LTS,
PureScript, kind, kubectl, Helm, Pulumi, and similar tools are resolved from their authoritative release
metadata at build-workflow time. GHCup selects its current recommended GHC and Cabal; Rustup selects the
stable Rust channel; package managers install current compatible quality/build tools.

There is no committed base-input version lock and rebuilding the same source revision need not reproduce
an older image. HTTPS is required for direct downloads and release queries. Provider-published integrity
metadata or installer verification should be used where practical, but it is not stored as a committed
replay manifest.

The rolling tag is the consumer discovery name. A registry digest can identify the exact result of one
publication and bind a pull-to-smoke workflow, but it does not imply locked inputs, reproducible rebuilds,
or a permanent digest-pinned consumer contract.

## Republishing

Published tags are the source of truth for derived projects. When
[`docker/basecontainer.Dockerfile`](../../docker/basecontainer.Dockerfile) or the cache-population inputs
under [`core/warm-deps/`](../../core/warm-deps/) change, an operator rebuilds and republishes the affected
native tag with `hostbootstrap base build-and-push`. Consumers pull the republished tag. A same-named
local image must not stand in for that published copy.

After pushing, the workflow pulls the tag and builds the real
[`demo/docker/Dockerfile`](../../demo/docker/Dockerfile) as a compatibility smoke. It may pass the pulled
digest to prevent a local-tag race within that one workflow. The smoke proves that the real consumer can
build from that publication; it does not prove offline behavior, complete cache reuse, or reproducible
inputs.

## What ships in the image

- No baked `hostbootstrap` binary. Each project builds its executable host-native and extends the fixed
  command tree through `runHostBootstrapCLI`.
- A broad Cabal store at `/opt/cache/cabal/`, populated from both manifests under `core/warm-deps/`.
  It is an opportunistic performance cache, not a freeze or version API.
- Current recommended GHC/Cabal, current compatible Fourmolu and HLint, and the Cabal build tools.
- Current stable Go and Rust toolchains, current Node LTS, PureScript, Spago, TypeScript, esbuild,
  Playwright, and purs-tidy.
- Docker/Compose, kind, kubectl, Helm, Skopeo, MinIO `mc`, AWS CLI v2, Pulumi, and nvkind.
- LLVM/Clang/LLD/BOLT and the ordinary C/C++ build toolchain from Ubuntu 24.04.
- CUDA/CuDNN in CUDA-flavor images through the selected NVIDIA parent.

Exact selected versions are observable in a particular build's output and resulting image. They are not
declared source-level API.

## Cabal cache contract

The base builds both warm dependency manifests through
[`core/warm-deps/cabal.project`](../../core/warm-deps/cabal.project). It generates no consumer freeze.
Derived builds use their normal host-compatible `cabal.project` unchanged and inherit `CABAL_DIR` plus
the store. Cabal reuses a matching artifact; otherwise it may update its index, solve, download, and
compile normally. See [warm store](warm_store.md).

The base still pre-builds the ways consumers commonly request (`tests`, `benchmarks`, shared libraries,
and optimization level 2) to improve hit probability. Those settings are optimization alignment, not a
guarantee that every future solver plan is present.

## Source and in-image gates

Before any registry mutation, the CLI runs the canonical Python code/coverage suite and the core and
demo Cabal build/test gates with warnings treated as errors. In the Dockerfile, Fourmolu and HLint run
against the warm-store sample source so a broken rolling tool selection fails the image build.

The accelerator daemon consumes compilers already present in the chosen image: Linux CPU uses Clang and
Linux GPU uses NVCC. Pods do not install compilers at runtime. Apple Silicon and Windows accelerator
lanes use separate host-native toolchains.

## Dockerfile rules

- Use the default POSIX `/bin/sh`; do not add a Bash `SHELL` directive.
- Avoid pipelines in `RUN` commands so failures remain direct.
- Use plain single-architecture `docker build`; do not use buildx, emulation, or manifest lists.
- Resolve architecture-specific URLs on the host and pass them as build arguments.
- Keep the one documented CUDA filesystem conditional that adds `/usr/local/cuda/lib64` to `ldconfig`
  only when the CUDA parent provides it.

Example:

```sh
poetry run hostbootstrap base build-and-push --flavor cpu --arch arm64
```

Run it only on a native arm64 host with an arm64 Docker engine. The equivalent amd64 command runs on an
amd64 host.

## Host-sized warm-store budget

The warm store is expensive to compile. On Linux the CLI measures available CPU/RAM, refuses below the
supported floor, caps the Docker build, and passes a memory-derived `CABAL_BUILD_JOBS`. When CPU and CUDA
build concurrently, they split the host budget; `--sequential` or `--flavor` gives one build the
available allocation. A plain Docker invocation retains the conservative Dockerfile default of one
Cabal job.

Resource-capped builds use the classic builder because buildx does not honor the required memory/CPU
controls. This is build-resource management, separate from project runtime cordoning.

## Publication authority

`base build` is a local inspection build. `base build-and-push` mutates Docker Hub and is run only with
explicit operator authorization. See [build and release](build_release.md) for ordering and evidence.
