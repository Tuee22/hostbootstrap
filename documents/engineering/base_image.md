# Base image

**Status**: Authoritative source
**Supersedes**: the immutable-input and layered-freeze base-image doctrine
**Referenced by**: [../README.md](../README.md), [warm_store.md](warm_store.md),
[derived_project_standards.md](derived_project_standards.md), [build_release.md](build_release.md),
[code_check_doctrine.md](code_check_doctrine.md)

> **Purpose**: Define the four rolling native-architecture base tags, their tool/cache contents, and
> the build and publication rules.

## Current Status

This page describes the published base and smoke as they stand. The
[base-image-publication-and-opportunistic-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md)
owes three changes to them: a smoke whose store step is separate from its toolchain step and requires a
store keyed to the image's own compiler, with a consumer whose dependencies reach past the store; a GHCup
toolchain installed outside `/root` so a non-root uid starts the same `ghc` and `cabal`; and a base
Dockerfile whose version probes compare a captured value instead of piping into `grep`, with a header that
names its host-resolved, build-time-rolling, and pinned inputs. Until they land, the image's toolchain is
on `PATH` under `/root/.ghcup/bin`, and the rules below describe the current smoke steps and the `grep`
version-assertion exception.

## Tags and architecture

Four single-architecture rolling tags carry the shared toolchain:

```text
docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64
docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64
docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64
docker.io/tuee22/hostbootstrap:basecontainer-cuda-arm64
```

The four names are the naming scheme. A tag exists in the registry only after a native host of its
architecture has run `build-and-push` for its flavor, and the dated publications, which name the tags
published so far, are recorded as gate evidence in the
[base-image-publication-and-opportunistic-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md).
`basecontainer-cuda-arm64` is built on demand ([CUDA on arm64](../languages/cuda.md#arm64)): a Linux GPU
consumer on arm64, which the demo maps to that tag, pulls it only after a native arm64 host has published
the CUDA flavor.

There are no manifest lists. Before any build, the CLI requires the requested architecture, detected
host architecture, and Docker-engine architecture to match. Buildx/emulation and cross-architecture
publication are rejected.

The maintainer `base` command selects an explicit CPU/CUDA flavor and architecture. A consuming project
separately maps its detected substrate to one published tag. The demo uses CPU for Apple Silicon,
Linux CPU, Windows CPU, and Windows GPU; it uses CUDA for Linux GPU. Windows accelerator workers remain
host-native and add no base flavor.

## Rolling input policy

A base rebuild intentionally discovers current upstream inputs. The CPU parent is the rolling Ubuntu
24.04 tag; CUDA resolution selects the highest-versioned `X.Y.Z-cudnn-devel-ubuntu24.04` tag that
publishes the requested native architecture and checks it against no host's NVIDIA driver
([CUDA](../languages/cuda.md#current-status) is canonical for the rule). Go, Node LTS,
PureScript, kind, kubectl, Helm, Pulumi, and similar tools are resolved from their authoritative release
metadata at build-workflow time. GHCup installs the **pinned** GHC the build argument names and its own
current recommended Cabal; Rustup selects the stable Rust channel. The package managers pin nothing: pip
and npm install the latest published releases (npm's global tools, Playwright, Poetry), and
`cabal install` installs the newest `fourmolu` and `hlint` its solver admits for the pinned GHC against
the index the build's `cabal update` fetched.

Three selections do not roll. The bootstrapper fixes each: `GHC_VERSION` in `hostbootstrap/bootstrap.py`
(imported by `hostbootstrap/base_image.py`), and `LLVM_MAJOR`, `CPU_BASE_IMAGE`, and the CUDA tag pattern
in `hostbootstrap/base_image.py`
([§ FF](../../DEVELOPMENT_PLAN/development_plan_standards.md#ff-rolling-base-selection-and-native-compatibility)
is canonical for the list and the reasons):

- the GHC version, shared with the host bootstrap, because the compiler keys the warm Cabal store rather
  than being discovered by it;
- the LLVM major (`LLVM_MAJOR`), because Ubuntu installs the LLVM toolchain packages by major version
  (`clang-<major>`, `lld-<major>`, `bolt-<major>`, `llvm-<major>`), so a new major is a deliberate change
  to that constant rather than a discovery;
- the Ubuntu 24.04 release line of both parents; within that line the parent tag and the CUDA version
  still roll.

There is no committed base-input version lock and rebuilding the same source revision need not reproduce
an older image. HTTPS is required for direct downloads and release queries. Provider-published integrity
metadata or installer verification should be used where practical, but it is not stored as a committed
replay manifest.

The rolling tag is the consumer discovery name. A registry digest can identify the exact result of one
publication and bind a pull-to-smoke workflow, but it does not imply locked inputs, reproducible rebuilds,
or a permanent digest-pinned consumer contract.

A publication's immutable local-ID smoke runs before the push and its exact pulled-digest smoke runs
afterward, and the resolved digest identifies that one publication; consumers continue to discover the
rolling tag. The dated publications and their digests belong to the
[base-image-publication-and-opportunistic-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md).

## Republishing

Published tags are the source of truth for derived projects. When
[`docker/basecontainer.Dockerfile`](../../docker/basecontainer.Dockerfile) or the cache-population inputs
under [`core/warm-deps/`](../../core/warm-deps/) differ from those of the publication recorded in the
owning development-plan sprint, the affected native tag is rebuilt and republished with
`hostbootstrap base build-and-push`, which agents run on that trigger (see
[publication authority](#publication-authority)). Consumers pull the republished tag. A same-named
local image must not stand in for that published copy.

Before pushing, the workflow cold-builds
[`docker/compatibility-smoke.Dockerfile`](../../docker/compatibility-smoke.Dockerfile) against the new
local base. A consumer incompatibility therefore refuses before registry mutation. After pushing, the
workflow pulls the tag and builds
[`docker/compatibility-smoke.Dockerfile`](../../docker/compatibility-smoke.Dockerfile) as a compatibility
smoke. It may pass the pulled digest to prevent a local-tag race within that one workflow.

The smoke checks three things, each as a separate `RUN` step and therefore a separate failure:

1. **The toolchain.** `ghc` and `cabal` start, `CABAL_DIR` is set and names a directory, and the warm-store
   project directory `/opt/basecontainer/haskell-deps` is present.
2. **The style tools.** `fourmolu` and `hlint` start. The code-check doctrine treats their presence as
   part of what the base guarantees, and an image missing either would fail every derived project's
   `check-code` at build time rather than here.
3. **A consumer's build plan.** The smoke writes a **separate consumer package**, with its own name,
   version and dependency list and no `cabal.project`, then runs `cabal build --dry-run all` on it. The
   step passes when Cabal resolves a complete build plan.

The consumer is a separate package rather than `/opt/basecontainer/haskell-deps` itself, but its
dependency closure still sits inside the store: every package it names (`base`, `bytestring`,
`containers`, `dhall`, `filepath`, `optparse-applicative`, `text`) is a GHC boot package or a member of
the core warm-store manifest's closure. Re-resolving a closure the store already holds is close to
tautological, so the step shows only that a consumer whose closure the store holds gets a plan; it does
not show that a derived project whose dependencies reach past the store can resolve one (see
[Current Status](#current-status) for the owed consumer). A plan that names downloads or builds is still
a pass — the warm store is an opportunistic cache rather than a lock — and a plan that cannot be produced
at all is the failure this catches.

The smoke compiles and links nothing, so it does not prove that the store's artifacts or the C toolchain
can build a consumer, and it does not prove offline behavior, complete cache reuse, or reproducible
inputs.

The smoke is deliberately not the demo's own
[`demo/docker/Dockerfile`](../../demo/docker/Dockerfile). That one authenticates a separately selected
builder through a named build context and consumes four `required=true` BuildKit secrets: the canonical
image-build config, the build channel carrying the binding the project binary's build coordinator signs,
the Build public key, and the coordinator identity. Each verified authority admits the `check-code` and
build phases at most once; the protocol claims no global replay protection (see
[authenticated derived-image gates](build_release.md#authenticated-derived-image-gates)). Driving that
Dockerfile from the Python bootstrapper would put build authority in a second place, outside the binary
that owns it, which is the shape
[§ KK](../../DEVELOPMENT_PLAN/development_plan_standards.md#kk-one-effect-vocabulary-and-no-scripts) exists
to prevent — so the demo's authenticated build stays with the coordinator that owns it and is exercised by the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). A publication gate asks the narrower
question it can answer on its own.

## What ships in the image

- No baked `hostbootstrap` binary. Each project builds its executable host-native and extends the fixed
  command tree through `runHostBootstrapCLI`.
- A broad Cabal store at `/opt/cache/cabal/`, populated from both manifests under `core/warm-deps/`.
  It is an opportunistic performance cache, not a freeze or version API.
- The pinned GHC and current recommended Cabal, current compatible Fourmolu and HLint, and the Cabal
  build tools.
- Current stable Go and Rust toolchains, current Node LTS, PureScript, Spago, TypeScript, esbuild,
  Playwright, and purs-tidy.
- Docker/Compose, kind, kubectl, Helm, Skopeo, MinIO `mc`, AWS CLI v2, Pulumi, and nvkind.
- LLVM/Clang/LLD/BOLT at the fixed LLVM major, linked at `/opt/llvm`, and the ordinary C/C++ build
  toolchain, all from Ubuntu 24.04 packages.
- CUDA/CuDNN in CUDA-flavor images through the selected NVIDIA parent.

Exact selected versions are observable in a particular build's output and resulting image. They are not
declared source-level API.

## Cabal cache contract

The base builds both warm dependency manifests through
[`core/warm-deps/cabal.project`](../../core/warm-deps/cabal.project). It generates no consumer freeze.
Derived builds use their normal host-compatible `cabal.project` unchanged and inherit `CABAL_DIR` plus
the store. Cabal reuses a matching artifact; otherwise it solves, downloads, and compiles normally. See
[warm store](warm_store.md).

The inherited `CABAL_DIR` also carries the Hackage package index as of the base build's `cabal update`.
`cabal build` does not refresh that index, so a derived build solves against the base's snapshot. A
consumer that needs a release published after that base build runs `cabal update` (or sets its own
`index-state`) in its own Dockerfile.

The warm-store project's top-level `tests`, `benchmarks`, `shared`, and `optimization: 2` settings reach
only its two manifest packages, not the dependencies cached in the store; see
[warm store](warm_store.md#population-inputs).

## Source and in-image gates

Before any image build, and so before any registry mutation, the CLI runs the source preflight listed in
[build and release](build_release.md#source-preflight). In the Dockerfile, Fourmolu and HLint run
against the warm-store sample source so a broken rolling tool selection fails the image build.

The accelerator daemon consumes compilers already present in the chosen image: Linux CPU uses Clang and
Linux GPU uses NVCC. Pods do not install compilers at runtime. Apple Silicon and Windows accelerator
lanes use separate host-native toolchains.

## Dockerfile rules

- Use the default POSIX `/bin/sh`; do not add a Bash `SHELL` directive.
- Avoid pipelines in `RUN` commands: `/bin/sh` has no `pipefail`, so a pipeline's status is only its last
  command's. The one exception is a version assertion that pipes a tool's version output into
  `grep -F` or `grep -Fx` against the expected version; the `grep` fails whenever the left side prints
  nothing or the wrong version, so the assertion still fails directly.
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

Off Linux, where Docker runs inside a VM that already bounds it, the CLI measures nothing, applies no
floor or caps, builds the base image with BuildKit, and the warm store builds with the Dockerfile default of one Cabal
job.

Resource-capped builds use the classic builder because buildx does not honor the required memory/CPU
controls. The pre-publish compatibility smoke also uses it because the daemon-local image ID must not be
reinterpreted as a registry reference; the post-publish digest smoke remains a BuildKit build with `--pull`.
This is build-resource and publication-identity management, separate from project runtime cordoning.

## Publication authority

`base build` is a local inspection build. `base build-and-push` first resolves the fresh local image ID
and proves the compatibility consumer against that immutable local artifact, then mutates Docker Hub
and verifies the pulled digest. A registry-backed
rolling tag is not sufficient for the pre-publish check because BuildKit may resolve it from the
registry even when `--pull` is absent, and BuildKit interprets a bare image ID in `FROM` as a repository
name. The pre-publish smoke therefore uses the classic builder for exact daemon-local ID resolution. See
[build and release](build_release.md) for ordering and evidence.

Agents build and publish the base images to Docker Hub as required. Publication is a standing part of the
rebuild → republish → pull rule, so an agent runs `build-and-push` itself, without waiting for fresh
direction, whenever the base inputs (`docker/basecontainer.Dockerfile` and the inputs under `core/warm-deps/`)
differ from those of the publication recorded in the owning development-plan sprint of the
[base-image-publication-and-opportunistic-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md).
The repository-environment gate on the `base` commands is a capability check, which an agent
passes by running them through `poetry run` from the repository checkout, and not a separate authorization.
The limits are the workflow's own and the credential policy's:

- only the affected native tags are published, one architecture per native host. The CLI refuses a
  request, host, and engine architecture disagreement before any Docker work, and an architecture with no
  native host in the session is reported as outstanding rather than emulated;
- the source preflight and the pre-publish consumer smoke run first, and any failure stops before registry
  mutation;
- the host's existing Docker Hub login supplies the credential, which is never printed, copied, or written
  (see [registry credential forwarding](registry_credentials.md));
- after the push the tag is pulled, its digest resolved, and the post-publish smoke run, and the dated
  publication and digest are recorded in the owning development-plan sprint;
- a partial failure reports which rolling tags changed, because there is no multi-tag transaction (see
  [evidence and partial failure](build_release.md#evidence-and-partial-failure) for how to read that
  from the command's output).

Publishing is a registry operation and not a git operation, so the git-history boundary in
[AGENTS.md](../../AGENTS.md) and [CLAUDE.md](../../CLAUDE.md) is unchanged.

## Validation

| Contract | Proved by |
|---|---|
| Tag naming, native-architecture build specs, rolling resolvers feeding the build arguments, and the host-sized budget | [`tests/test_base_image.py`](../../tests/test_base_image.py), run by the Python test runner |
| The smoke's consumer is the dedicated Dockerfile, needs only the base reference, and mounts no secret or named build context; the bootstrapper reaches no `demo/` path | the compatibility-smoke cases of [`tests/test_base_image.py`](../../tests/test_base_image.py) |
| One GHC version governs the host bootstrap, the image build, and the guest | the GHC-version case of [`tests/test_base_image.py`](../../tests/test_base_image.py) |
| A fresh image passes the three smoke steps before any registry mutation | the pre-publish build of [`docker/compatibility-smoke.Dockerfile`](../../docker/compatibility-smoke.Dockerfile) against the immutable local image ID |
| The published tag passes the same steps | the post-publish build of the same Dockerfile against the exact pulled digest |

The dated publications, their digests, and both smoke results are recorded as `**Gate evidence**` rows in
the [base-image-publication-and-opportunistic-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md).
