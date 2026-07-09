# CUDA

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [cpp.md](cpp.md), [composition_patterns](../engineering/composition_patterns.md), [wsl2](../engineering/wsl2.md)

> **Purpose**: Document the CUDA-flavored base image and how its CUDA toolchain is selected.

This page documents what the cuda-flavored base image ships. The sections below — the dynamically
resolved `nvidia/cuda:*-cudnn-devel-ubuntu24.04` base, `ldconfig`, CUDA drift, and arm64 — all describe
the **in-container, `linux-gpu` CUDA path**: the GPU toolchain baked into the base image and reached at
runtime through the `nvidia-container-toolkit` runtime (readied by `ensure cuda`). A second, distinct
path — building CUDA artifacts on a bare Windows host — is described separately under
[Windows Host-Build CUDA (headless)](#windows-host-build-cuda-headless).

The `basecontainer-cuda-<arch>` tags are built `FROM` the latest
`nvidia/cuda:*-cudnn-devel-ubuntu24.04` image that has a manifest for the
target arch. Resolution lives in
[`hostbootstrap/base_image.py`](../../hostbootstrap/base_image.py):

1. Query Docker Hub for `nvidia/cuda` tags matching
   `*-cudnn-devel-ubuntu24.04`.
2. Sort by semver descending.
3. Pick the first tag whose `images` array carries the target arch.

The selected tag becomes `--build-arg BASE_IMAGE=nvidia/cuda:…` at build
time.

## Ldconfig

The Dockerfile checks for `/usr/local/cuda/lib64`; when present it adds the
path to `/etc/ld.so.conf.d/cuda.conf` and runs `ldconfig`. This is a build-time
filesystem check, not version-resolution logic, so it stays in the Dockerfile.

## CUDA drift

Dynamic resolution always pulls the latest `cudnn-devel-ubuntu24.04` tag. A
project pinned to an older CUDA must override the resolved base explicitly
through the Python build API — `compute_build_args(base_image_override=…)` or
`with_base_override` in [`hostbootstrap/base_image.py`](../../hostbootstrap/base_image.py). The
`hostbootstrap base build-and-push` CLI exposes only `--flavor`, `--arch`,
`--context`, and `--sequential`; it carries no base-image override flag.

## arm64

`basecontainer-cuda-arm64` is supported by the naming scheme and built on
demand. GPU projects run on amd64 in practice.

## Windows Host-Build CUDA (headless)

Everything above describes the **in-container `linux-gpu`** path: nvcc and the CUDA runtime live inside
the base image, and a container reaches the GPU through the `nvidia-container-toolkit` runtime. Windows
adds a **distinct, second** path — a **headless host build**, the first worked instance of composition
pattern #7 (see [composition_patterns](../engineering/composition_patterns.md)).

On a `windows-gpu` host, `ensure cudawin` readies the Windows GPU build toolchain. The NVIDIA Windows
display driver is a **precondition** — the reconciler fails fast when `nvidia-smi` is absent, so it is
never auto-installed — while the CUDA Toolkit (`Nvidia.CUDA`) and the MSVC host compiler are installed
via **winget** (the Homebrew-analog pre-binary package manager). `nvcc` then compiles the platform-locked
artifact **on the bare Windows host**, and the chain stages the produced artifact into the cluster. **No
workload runs in a build VM**;
the build VM is absent by design. This is the headless host-bridge shape: build a platform-locked
artifact on the metal host, copy it out, and never run the workload there.

The two paths contrast explicitly:

- **In-container `linux-gpu` (the sections above).** The GPU toolchain is in the base image and the
  workload *runs* in a GPU container through `nvidia-container-toolkit`; readied by `ensure cuda`.
- **Windows host-build (`windows-gpu`, this section).** nvcc *builds* on the bare Windows host through
  `ensure cudawin` (CUDA Toolkit + MSVC via winget; the NVIDIA driver is a required precondition); the
  artifact is staged into the cluster and nothing GPU-bound runs in a build VM.

This Windows host-build path is implemented as the `ensure cudawin` headless host-build surface. The
Windows VM frame it sits beside (Docker, kind, and the in-cluster workload) is the
[wsl2](../engineering/wsl2.md) host provider, the Windows peer of the Lima and Incus VM providers; the
headless host build is deliberately *outside* that VM. The full Windows/WSL2 lifecycle closed in phase 11:
the Windows lifecycle runs end to end through `test run all` (`6/6`) and `project destroy`.

## Accelerator Daemon CUDA Lane

The planned accelerator daemon uses CUDA in two places:

- `linux-gpu`: the daemon runs as a Kubernetes pod from the CUDA hostbootstrap base image, builds the
  generated add worker with in-image `nvcc`, and trusts that the NVIDIA runtime is available to the
  `nvkind` cluster. It does not run host ensure inside the pod.
- `windows-gpu`: the daemon runs host-native, uses `ensure-cudawin` to verify/install the host CUDA build
  stack (`Nvidia.CUDA`, MSVC C++ Build Tools, and LLVM clang), builds the generated CUDA worker with host
  `nvcc`, and connects to the cluster web service through a local-only NodePort.

The browser e2e test for the demo must assert backend metadata returned by the daemon so an in-process
fallback cannot satisfy the CUDA lane. See [accelerator_daemon](../engineering/accelerator_daemon.md).
