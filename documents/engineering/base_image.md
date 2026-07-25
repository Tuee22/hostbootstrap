# Base image

**Status**: Authoritative source
**Supersedes**: prior base-image notes without metadata
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

There are no manifest lists. The base flavor (`cpu`/`cuda`) and requested `--arch`
(`amd64`/`arm64`) together name exactly one tag. The design requires that request to match the native
host/Docker-engine architecture, but the current CLI does not validate the match; Phase 6 Sprint 6.7
owns the fail-closed preflight.

## Republishing the base

The four published tags above are the **source of truth** every derived project (and the in-repo
`demo/`) builds `FROM`. Whenever the repo's base inputs change — `docker/basecontainer.Dockerfile`
or the warm-store inputs under [`core/warm-deps/`](../../core/warm-deps/) (the layer
manifests, the `*.project` files, or the `core.freeze`/`daemon.freeze` projection) — the published
tag falls out of sync with the repo and **must be rebuilt and republished**
(`hostbootstrap base build-and-push`; see [build_release.md](build_release.md)). Consumers then
**pull** the republished tag; they never rebuild the base as a one-off and never build against an
un-republished local base, which would hide the drift between the repo and the registry. A freeze a
consumer imports (`core.freeze`, `daemon.freeze`) must exist in the **currently published** tag, not
only in the repo — otherwise the consumer's container build cannot resolve the import.

The current derived builder still accepts the mutable tag and does not force a pull, so a same-named
local image can win. That is an open implementation defect. The target explicitly pulls the tag, resolves
its repository digest, and builds `FROM repository@sha256:...`; see
[build and release](build_release.md).

## Flavor And Arch Selection

There are two separate selection surfaces:

- The Python `base` command is the **maintainer base-build** surface. Its `Flavor` enum, tag builders,
  and `substrate_to_flavor` helper belong to that surface; `base build` /
  `base build-and-push` build the explicitly requested `--flavor`, or both flavors when it is omitted.
  `--arch` defaults to the detected host architecture. This Python code does not choose the base tag for
  a consuming project's derived image.
- The consuming project binary chooses the published tag for its own derived image. In the in-repo demo,
  Haskell's `demoBaseImageFor` maps the detected `Substrate` and architecture to the
  `basecontainer-<flavor>-<arch>` reference passed to the project-container build. Core intentionally has
  no universal `Flavor` type because flavor choice is a consumer policy.

The current demo mapping is:

| detected substrate | base flavor |
|---|---|
| `apple-silicon` | `cpu` |
| `linux-cpu` | `cpu` |
| `linux-gpu` | `cuda` |
| `windows-cpu` | `cpu` |
| `windows-gpu` | `cpu` (the accelerator worker is host-native; see below) |

| detected host | arch | resolved tag |
|---|---|---|
| `apple-silicon` | arm64 | `basecontainer-cpu-arm64` |
| `linux-cpu` (amd64) | amd64 | `basecontainer-cpu-amd64` |
| `linux-cpu` (arm64) | arm64 | `basecontainer-cpu-arm64` |
| `linux-gpu` (amd64) | amd64 | `basecontainer-cuda-amd64` |
| `linux-gpu` (arm64) | arm64 | `basecontainer-cuda-arm64` (built on demand) |
| `windows-cpu` / `windows-gpu` (amd64) | amd64 | `basecontainer-cpu-amd64` |

The demo's substrate is detected, never declared (see [schema.md](schema.md)).

Python discovers project build metadata but does not evaluate Dhall, so Linux/arm64 support does not
depend on a Python-provisioned Dhall binary. Its current Cabal-stem/executable identity split is unrelated
to base flavor selection; the development plan owns that identity repair.

### Windows adds no base flavor

The Windows substrates (`windows-cpu` / `windows-gpu`) add **no** new base-image flavor. The current demo
maps both to the CPU base tag for the WSL2-hosted project container. WSL2 is the host-provider VM that
supplies that Linux guest (see [wsl2.md](wsl2.md)); it changes where the project container runs, while
the Haskell demo policy still chooses the published tag it builds `FROM`.

The host-native Windows CUDA capability is a **separate concern** and likewise not a base-image flavor:
the accelerator daemon uses `ensure cudawin`, builds and runs its worker on bare Windows, and connects to
the WSL2-hosted service. It does not stage the worker into the cluster. Generic build-only host staging is
still available as composition pattern #7. See
[composition_patterns.md](composition_patterns.md). The four published tags above remain the complete
flavor × arch set.

## What ships in the image

* **No baked `hostbootstrap` binary** — the image bakes no `hostbootstrap` executable. A baked binary
  is a Linux ELF and cannot run on Apple silicon, so it could not be copied out to every host.
  Instead every project builds its own binary **host-native** on every substrate, extending the core
  tree via `runHostBootstrapCLI progName projectSpec`; see
  [derived_project_standards.md](derived_project_standards.md). The bare `hostbootstrap` binary
  (`hostbootstrap-core`'s own executable, with the fixed command tree but no project-specific
  extensions) is built the same way, not pre-baked.
* **Warm `hostbootstrap-core` dependency closure** — `hostbootstrap-core`'s transitive dependency
  closure is compiled into the warm Cabal store at `/opt/cache/cabal/` alongside the shared
  warm-store deps, so a project that extends the core hits the cache for the core's dependencies
  during the in-container project-container build. (`/opt/cache/cabal/` exists only inside the image;
  the host-native binary build uses its own repo-local store at `.build/cabal-store/` — see
  [build_and_run_model.md](../architecture/build_and_run_model.md) — and compiles the closure on the
  host, cold on a freshly cleaned tree.) The warm store
  itself is **shared**, but the version-pin freezes it produces are **layered** by library level:
  `core.freeze` (base + the `hostbootstrap-core` closure + the shared web-build extras — including
  `purescript-bridge` and the web-server stack `warp`/`wai*`/`network`) and `daemon.freeze` (the
  daemon-family deps — Redis/Postgres/proto/secure-WS-client). An L0-direct consumer imports
  `core.freeze`; a daemon app imports `core.freeze` **and** `daemon.freeze`. The base build projects
  the shared store into the two fragments in-image — `cabal freeze --project-file=core.project` and
  `--project-file=daemon.project`, moved to `core.freeze`/`daemon.freeze` — and they are **never
  committed** (`.gitignore` and `.dockerignore` exclude `cabal.project.freeze`, `core.freeze`,
  `daemon.freeze`, and the `*.project.freeze` intermediates). See [warm_store.md](warm_store.md).
* **Haskell** — GHC 9.12.4, Cabal 3.16.1.0, pinned fourmolu `0.19.0.1` / hlint `3.10` at
  `/opt/hostbootstrap/haskell-style/bin/` with `/usr/local/bin` symlinks, and the warm Cabal store
  from [`core/warm-deps/`](../../core/warm-deps/).
* **Go** — first-class toolchain installed at `/opt/go`; `GOPATH`, `GOCACHE`, `GOMODCACHE`,
  `GOTOOLCHAIN`, and `PATH` set alongside other languages.
* **nvkind** — currently built with
  `CGO_ENABLED=1 go install github.com/NVIDIA/nvkind/cmd/nvkind@latest`. This is an unpinned input and a
  reproducibility defect; the target manifest supplies an immutable module version and checksum.
* **Node** — latest Node LTS (non-LTS/current releases are excluded because tools like Spago lag the
  newest major), with npm, esbuild, TypeScript, Playwright (Chromium/Firefox/WebKit),
  Spago, purs-tidy. Playwright is installed globally under the npm prefix
  `/opt/build/node/global`; project-local specs that import `@playwright/test` without their own
  `node_modules` run with `NODE_PATH=/opt/build/node/global/lib/node_modules`.
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

### Accelerator daemon base contract

The accelerator daemon uses the published base images directly for in-cluster Linux lanes:

- `linux-cpu` daemon pods run from the CPU base and build the generated C++ worker with the base-provided
  `clang++`;
- `linux-gpu` daemon pods run from the CUDA base and build the generated CUDA worker with the
  base-provided `nvcc`;
- no in-cluster daemon pod runs `ensure` to install compilers. A missing compiler in the pod is treated as
  a stale or incorrect base image, not as something the pod remediates at runtime.

The deterministic C++/CUDA source templates and build arguments are implemented in
`HostBootstrapDemo.Accelerator`; real in-pod build/run validation remains an accelerator integration gate.

Host-resident accelerator lanes are separate from the base-image contract. Apple Silicon ensures the host
Swift/Metal build stack; Windows GPU ensures the host CUDA/MSVC/clang build stack. See
[accelerator_daemon.md](accelerator_daemon.md).

See [`docker/basecontainer.Dockerfile`](../../docker/basecontainer.Dockerfile) for the exact
instructions. Architecture/version discovery is host-side, but the resulting build is not reproducibly
pinned: several resolvers select “latest” at invocation time; Ubuntu/CUDA bases are tags rather than
digests; nvkind, npm, and pip installs are unpinned; and downloaded archives/binaries are not uniformly
checked against expected digests.

## Current Status

Today `compute_build_args` queries upstream release APIs for current Go, Node LTS, PureScript, kind,
kubectl, Helm, Pulumi, and CUDA values. It then passes the resolved URLs/versions to Docker. This makes the
Dockerfile free of version-discovery branches, but a rebuild from the same source on a later day can
select different inputs. URL versioning and TLS do not replace content verification.

### Dynamic-pinning target

The target keeps host-side resolution as an explicit **update** workflow, not an implicit build step:

1. a reviewed lock manifest records every base digest, package/module version, download URL, checksum,
   and signer policy;
2. normal builds read only that manifest and perform no “latest” queries;
3. the Dockerfile receives exact values plus expected digests and verifies each artifact before
   install/execution;
4. apt/npm/pip/Go/Rust inputs are locked or represented by a documented immutable snapshot;
5. the published image reports the lock-manifest fingerprint and resulting repository digest.

The base publish preflight also currently runs only the Python code check; it does not run the repository
Haskell gate before Docker/registry mutation. See [build and release](build_release.md).

## Dockerfile rules

The Dockerfile is deliberately constrained so a build is host-native and free of shell indirection.
Those constraints do not make the current dynamically resolved build reproducible; the lock-and-verify
target above is the missing reproducibility contract. These rules also apply to downstream project Dockerfiles; see
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
> poetry run hostbootstrap base build-and-push --arch amd64
> ```
>
> Run this example on a native amd64 host/Docker engine; run an arm64 request on a native arm64 peer.
> The current CLI does not reject a mismatched request, so matching the host is an operator obligation
> until Phase 6 Sprint 6.7 lands. Plain `docker build` under the hood, single-arch, host-native, with
> host-resolved build arguments where
> the current CLI computes them, and immediate `docker push`es for the CPU and CUDA tags so the registry
> copies match the just-built local layers. The Dockerfile still performs additional unpinned npm/pip
> installs, including `nvkind@latest`; those are target gaps, not host-computed locks. The CPU and CUDA
> tags build **concurrently** by default (`--sequential`
> opts out) — that is host-level parallelism of two independent single-arch `docker build`s, **not** a
> buildx multi-platform manifest, which stays forbidden (see [build_release.md](build_release.md)).

### Host-sized warm-store build budget

The warm Cabal store is compiled at `-O2` with the vanilla **and** dynamic ways enabled — RAM-hungry,
especially the `criterion`/`statistics`/`math-functions` numeric subtree. An **unbounded** `cabal
build all` fans out to `-j$ncpus`, and enough concurrent `-O2` GHC processes can exhaust host memory;
when they do, the GHC RTS dies with **SIGSEGV** rather than a clean OOM. (This is distinct from the
`--jobs=1` rule above, which concerns the forbidden buildx orchestrator flag, not cabal's `-j`.)

So the base build is **resource-managed, not guessed**. Before building, `hostbootstrap base
build`/`build-and-push` measures the host (`hostbootstrap/resources.py`: CPU affinity +
`/proc/meminfo`) and:

* **refuses below a floor** — the supported build machine is **16 GB RAM / 8 CPUs**, so the floor is
  8 CPUs / 14 GiB total / 8 GiB available (a real 16 GB box reports ~15.5 GiB total; 12 GB fails) —
  with remediation guidance, and
* **caps each build** — passing `docker build --memory/--memory-swap` plus
  `--cpu-period/--cpu-quota`, and a *memory-derived*
  `cabal build all -j<N>` (the `CABAL_BUILD_JOBS` build-arg) so the warm-store compile provably fits
  under the memory cap instead of OOM-racing. When the CPU and CUDA tags build concurrently the host
  budget is split between them (`--sequential` gives each the whole host).

On the 16 GB / 8 CPU reference, a single-flavor build (or `--sequential`) resolves to roughly
`--memory ~10–12g`, a seven-CPU CFS quota (`--cpu-period 100000 --cpu-quota 700000`), and `cabal -j4` —
memory is the binding constraint there, not the cores,
and `-j4` is the largest fan-out that provably fits. Building both flavors concurrently splits that in
half (`-j2` each), so on a 16 GB box prefer `--flavor`/`--sequential`.

The sizing is Linux-only (off Linux, docker already runs inside a resource-bounded VM); a plain
`docker build` with no `CABAL_BUILD_JOBS` arg keeps the conservative Dockerfile default of `-j1`.

Per-build resource caps are honoured only by the **classic** builder (`docker buildx build` rejects
`--memory`/`--cpu-*`), so a resource-capped build sets `DOCKER_BUILDKIT=0` — consistent with the
no-buildx rule above. The classic builder has no `--cpus`, so the CPU cap is expressed as a CFS quota
(`--cpu-period 100000 --cpu-quota <cpus×100000>`), the same decomposition `--cpus` uses.

### The one CUDA exception

There is exactly **one** permitted conditional in the Dockerfile: an
`if [ -d /usr/local/cuda/lib64 ]` block that, when the directory exists, adds it to
`/etc/ld.so.conf.d/cuda.conf` and runs `ldconfig`. A single Dockerfile serves both the `cpu` and
`cuda` bases via the `BASE_IMAGE` arg, and only the cuda base ships that directory. This is a
**build-time filesystem check**, not version-resolution logic and not a runtime probe — it needs no
GPU, driver, or CUDA runtime, so the cuda image still builds on a host with no CUDA hardware. See
[`languages/cuda.md`](../languages/cuda.md).
