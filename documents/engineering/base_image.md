# Base image

**Status**: Authoritative source
**Supersedes**: the substrate-keyed base-flavor selection and `--force-target` arch/flavor model
**Referenced by**: [../README.md](../README.md), [warm_store.md](warm_store.md), [derived_project_standards.md](derived_project_standards.md), [build_release.md](build_release.md), [code_check_doctrine.md](code_check_doctrine.md)

> **Purpose**: Describe the four prebuilt base tags and the warm `hostbootstrap-core` dependency
> closure they bake in (no `hostbootstrap` binary is baked), and the Dockerfile rules every image
> follows.

## Tags

Four single-arch, prebuilt tags carry the shared toolchain:

```
docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64
docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64
docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64
docker.io/tuee22/hostbootstrap:basecontainer-cuda-arm64
```

There are no manifest lists. The base flavor (`cpu`/`cuda`) and the host arch (`amd64`/`arm64`)
together name exactly one tag.

## Flavor And Arch Selection

The base-image **flavor** follows the detected substrate, and the **arch** follows the host.
Substrate detection is the shared concept and lives in `hostbootstrap-core`. The flavor mapping
itself — the `Flavor` enum and the substrate-to-flavor rule — currently lives only in the Python
bootstrapper (`base_image.substrate_to_flavor`); core has no `Flavor` type today. Moving flavor
mapping into `hostbootstrap-core` is the target, not present fact: until then, the Python
bootstrapper picks the flavor it needs for the build it is about to run.

| detected substrate | base flavor |
|---|---|
| `apple-silicon` | `cpu` |
| `linux-cpu` | `cpu` |
| `linux-gpu` | `cuda` |

| detected host | arch | resolved tag |
|---|---|---|
| `apple-silicon` | arm64 | `basecontainer-cpu-arm64` |
| `linux-cpu` (amd64) | amd64 | `basecontainer-cpu-amd64` |
| `linux-cpu` (arm64) | arm64 | `basecontainer-cpu-arm64` |
| `linux-gpu` (amd64) | amd64 | `basecontainer-cuda-amd64` |
| `linux-gpu` (arm64) | arm64 | `basecontainer-cuda-arm64` (built on demand) |

There is no force-target override: substrate is detected, never declared (see [schema.md](schema.md)).

The four-tag scheme above covers Linux/arm64, but the pre-binary Python layer cannot yet run there:
`dhall_tool.py` pins a `dhall-to-json` release asset only for Darwin/arm64, Darwin/amd64, and
Linux/amd64 — there is no Linux/arm64 asset. Until that asset is added, `hostbootstrap doctor` and
`hostbootstrap up` cannot run on a Linux/arm64 **host**, so Linux is effectively amd64-only for the
pre-binary bootstrapper (the `linux-cpu` arm64 and `linux-gpu` arm64 rows describe the target tag
scheme, not a host the bootstrapper reaches today).

## What ships in the image

* **No baked `hostbootstrap` binary** — the image bakes no `hostbootstrap` executable. A baked binary
  is a Linux ELF and cannot run on Apple silicon, so it could not be copied out to every host.
  Instead every project builds its own binary **host-native** on every substrate, extending the core
  tree via `runHostBootstrapCLI progName projectCommands`; see
  [derived_project_standards.md](derived_project_standards.md). The bare `hostbootstrap` binary
  (`hostbootstrap-core`'s own executable, no project commands) is built the same way, not pre-baked.
* **Warm `hostbootstrap-core` dependency closure** — `hostbootstrap-core`'s transitive dependency
  closure is compiled into the warm Cabal store at `/opt/cache/cabal/` alongside the shared
  warm-store deps, so a project that extends the core hits the cache for the core's dependencies on
  both the host-native binary build and the in-container project-container build. The warm store
  itself is **shared**, but the version-pin freezes it produces are **layered**: the base build
  runs `cabal freeze` in-image to emit `core.freeze` (base + the `hostbootstrap-core` closure + the
  shared web-build extras, including `purescript-bridge`) and `daemon.freeze` (the daemon-family
  deps — Pulsar/MinIO/proto/HTTP). An L0-direct consumer imports `core.freeze`; a daemon app imports
  `core.freeze` **and** `daemon.freeze`. Both freezes are generated in-image and **never committed**
  (`.gitignore` and `.dockerignore` exclude `cabal.project.freeze`, `core.freeze`, and
  `daemon.freeze`). See [warm_store.md](warm_store.md).
* **Haskell** — GHC 9.12.4, Cabal 3.16.1.0, pinned fourmolu `0.19.0.1` / hlint `3.10` at
  `/opt/hostbootstrap/haskell-style/bin/` with `/usr/local/bin` symlinks, and the warm Cabal store
  from [`haskell/haskell-deps/`](../../haskell/haskell-deps/).
* **Go** — first-class toolchain installed at `/opt/go`; `GOPATH`, `GOCACHE`, `GOMODCACHE`,
  `GOTOOLCHAIN`, and `PATH` set alongside other languages.
* **nvkind** — built once in the final image (`CGO_ENABLED=1 go install …/nvkind@latest`) and copied
  to `/usr/local/bin/nvkind`.
* **Node** — latest upstream Node, with npm, esbuild, TypeScript, Playwright (Chromium/Firefox/WebKit),
  Spago, purs-tidy.
* **PureScript** — latest `purs`.
* **Python** — Ubuntu 24.04 default Python with Poetry as the only global package, plus the
  build-essentials toolchain.
* **Kube tooling** — Docker CLI/compose (no buildx), kind, kubectl, helm, skopeo, MinIO `mc`,
  AWS CLI v2, Pulumi.
* **C/C++/LLVM** — build-essential, the latest available `llvm-N` family (LLVM 19 on Ubuntu 24.04),
  clang, clang PGO runtime, BOLT, LLD; CMake, Ninja, Make; `CC=clang-N` and `CXX=clang++-N`.
* **Rust** — `rustup` with Rust `1.95.0`, `llvm-tools-preview`, and `rustfmt`.
* **CUDA (cuda flavor only)** — built on top of the latest
  `nvidia/cuda:*-cudnn-devel-ubuntu24.04` with a manifest for the target arch.

See [`docker/basecontainer.Dockerfile`](../../docker/basecontainer.Dockerfile) for the exact
instructions. The Dockerfile is **logic-free**: every dynamic value (versions, URLs, arch strings,
the CUDA base image) arrives as a `--build-arg`, resolved on the host before the build.

## Dockerfile rules

The Dockerfile is deliberately constrained so a build is reproducible, host-native, and free of
shell indirection. These rules also apply to downstream project Dockerfiles; see
[derived_project_standards.md](derived_project_standards.md) for the full set of conventions a
derived project follows.

* **No `/bin/bash`.** The default POSIX `/bin/sh` is used; there is **no `SHELL` directive**.
  Anything needing bash-only syntax does not belong in a layer.
* **No pipes.** A `RUN` step never pipes one command into another — split it into discrete steps
  (or a copied script) so each command's exit status is checked.
* **No `docker-buildx`** and **no `--jobs=1`.** A build is single-arch and host-native; buildx exists
  only to assemble cross-arch manifest lists, which are forbidden (see [build_release.md](build_release.md)).

> **WRONG**
>
> ```sh
> docker buildx build --platform linux/amd64,linux/arm64 \
>   --build-arg BASE_IMAGE=… -f docker/basecontainer.Dockerfile .
> ```
>
> `buildx --platform` emits a manifest list and pulls in emulation to build an arch the host cannot
> run natively — exactly the cross-arch artifact the design rejects.
>
> **RIGHT**
>
> ```sh
> hostbootstrap base build-and-push --arch amd64
> ```
>
> Plain `docker build` under the hood, single-arch, host-native, with every version/URL computed on
> the host, and immediate `docker push`es for the CPU and CUDA tags so the registry copies match the
> just-built local layers (see [build_release.md](build_release.md)).

### The one CUDA exception

There is exactly **one** permitted conditional in the Dockerfile: an
`if [ -d /usr/local/cuda/lib64 ]` block that, when the directory exists, adds it to
`/etc/ld.so.conf.d/cuda.conf` and runs `ldconfig`. A single Dockerfile serves both the `cpu` and
`cuda` bases via the `BASE_IMAGE` arg, and only the cuda base ships that directory. This is a
**build-time filesystem check**, not version-resolution logic and not a runtime probe — it needs no
GPU, driver, or CUDA runtime, so the cuda image still builds on a host with no CUDA hardware. See
[`languages/cuda.md`](../languages/cuda.md).
