# CUDA

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [cpp.md](cpp.md), [composition_patterns](../engineering/composition_patterns.md), [wsl2](../engineering/wsl2.md)

> **Purpose**: Document the CUDA-flavored base image and how its CUDA toolchain is selected.

This page documents what the cuda-flavored base image ships. The sections below — the dynamically
resolved `nvidia/cuda:*-cudnn-devel-ubuntu24.04` base, `ldconfig`, CUDA drift, and arm64 — all describe
the **in-container, `linux-gpu` CUDA path**: the GPU toolchain baked into the base image and reached at
runtime through the `nvidia-container-toolkit` runtime (readied and proved by `ensure cuda`). The host
NVIDIA kernel driver is a precondition: `ensure cuda` requires `nvidia-smi -L` to report a GPU, but owns
the install-and-verify lifecycle for the container toolkit. A second, distinct path — building CUDA
artifacts on a bare Windows host — is described separately under
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

## Linux GPU Runtime And Direct Lane

`ensure cuda` bootstraps NVIDIA's signed Debian apt source into the dedicated
`nvidia-container-toolkit-keyring.gpg` keyring and rewrites the repository entry with its `signed-by`
binding before installing `nvidia-container-toolkit`. It then runs both required runtime configuration
steps:

1. `nvidia-ctk runtime configure --runtime=docker --set-as-default --cdi.enabled` makes the NVIDIA
   runtime Docker's default and enables CDI.
2. `nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place` enables the
   device-volume injection that `nvkind` consumes.

After restarting Docker, the reconciler verifies the exact volume-mount path used by `nvkind`, not just
the presence of a runtime name:

```sh
docker run --rm \
  -v /dev/null:/var/run/nvidia-container-devices/all \
  ubuntu:20.04 nvidia-smi -L
```

Only an exit-success result that reports a GPU is a satisfied no-op. A registered but misconfigured
runtime is reconciled again and then fails closed if the smoke still cannot see a device.

The demo's direct `linux-gpu` chain has no provider VM. On the metal host it runs the shared resource
preflight, `ensure docker`, and `ensure cuda`, then builds `hostbootstrap-demo:local` from the published
`basecontainer-cuda-<arch>` image. The handoff starts that project container with `--gpus=all`; its
validated direct-topology witness selects `NvkindDriver` and `nvkind-in-cluster.yaml` instead of
re-detecting the nested container as an ordinary CPU host.

That template is explicit: one control-plane node carries the public web/registry mappings and one GPU
worker carries `/dev/null` at `/var/run/nvidia-container-devices/all`. Cluster bring-up repeats the
runtime smoke and waits for both nodes, then probes allocatable GPU before any Helm or `kubectl` mutation.
An already-positive allocation is a no-op; otherwise cluster bring-up installs pinned NVIDIA device-plugin
chart `0.19.3`, waits for its pods, and refuses to continue until at least one node advertises positive
allocatable `nvidia.com/gpu`. The accelerator daemon pod requests `nvidia.com/gpu: 1` and reaches the web
process through the dedicated in-cluster accelerator Service; no accelerator NodePort is published for
this lane.

The planners, probes, topology choice, plugin gate, GPU request, CUDA base selection, and `--gpus=all`
handoff are covered by the current static baseline (364 core tests and 87 demo tests). Phase 3.7 closed on
2026-07-15 in a named Ubuntu 24.04 WSL2 guest classified `linux-gpu` on an RTX 3090 Windows machine: the
first run installed and verified the eight-step runtime plan, and the immediate second run exited 0 with
`ensure cuda: present (no-op)`. This was a WSL2 guest, not native Linux. Phase 5.5 remains `Active` until
the native Linux GPU direct-nvkind/CUDA/browser lane reports `8/8`.

## Windows Host-Build CUDA (headless)

Everything above describes the **in-container `linux-gpu`** path: nvcc and the CUDA runtime live inside
the base image, and a container reaches the GPU through the `nvidia-container-toolkit` runtime. Windows
adds a **distinct, second** host-native path. Generic consumers may use the headless build-and-stage
pattern #7, but the accelerator uses host-daemon pattern #6: it builds and runs the worker on Windows
(see [composition_patterns](../engineering/composition_patterns.md)).

On a `windows-gpu` host, `ensure cudawin` readies the Windows GPU build toolchain. The NVIDIA Windows
display driver is a **precondition** — the reconciler fails fast when `nvidia-smi` is absent, so it is
never auto-installed — while the CUDA Toolkit (`Nvidia.CUDA`), Visual Studio Build Tools with the VCTools
workload, and LLVM clang (`LLVM.LLVM`) are installed via **winget** (the Homebrew-analog pre-binary package
manager). The reconciler verifies `vswhere`, the resolved MSVC `cl.exe`, LLVM clang, and a CUDA smoke
compile through `nvcc -ccbin <resolved-msvc-cl-directory>`. The accelerator daemon then compiles the
platform-locked worker **on the bare Windows host and runs it there**. The WSL2 VM still owns Docker/kind,
but no GPU workload runs in that VM and the worker is not staged into the cluster.

The two paths contrast explicitly:

- **In-container `linux-gpu` (the sections above).** The GPU toolchain is in the base image and the
  workload *runs* in a GPU container through `nvidia-container-toolkit`; readied by `ensure cuda`.
- **Windows host daemon (`windows-gpu`, this section).** nvcc *builds and runs* on the bare Windows host through
  `ensure cudawin` (CUDA Toolkit + MSVC VCTools + LLVM clang via winget; the NVIDIA driver is a required
  precondition); nothing GPU-bound runs in the WSL2 VM.

This Windows host-runtime path is implemented through `ensure cudawin` plus the accelerator daemon. The
Windows VM frame it sits beside (Docker, kind, and the in-cluster workload) is the
[wsl2](../engineering/wsl2.md) host provider, the Windows peer of the Lima and Incus VM providers; the
headless host build is deliberately *outside* that VM. The full Windows/WSL2 lifecycle closed in phase 11:
the Windows lifecycle runs end to end through `test run all` (`6/6`) and `project destroy`.

## Accelerator Daemon CUDA Lane

The accelerator daemon design uses CUDA in two places:

- `linux-gpu`: the daemon runs as a Kubernetes pod from the CUDA hostbootstrap base image, builds the
  generated add worker with in-image `nvcc`, and requests one `nvidia.com/gpu`. Host-side `ensure cuda`,
  the `nvkind` volume-mount smoke, device-plugin readiness, and the allocatable-GPU gate all complete
  before that pod is deployed. It does not run host ensure inside the pod.
- `windows-gpu`: the daemon runs host-native, uses `ensure-cudawin` to verify/install the host CUDA build
  stack (`Nvidia.CUDA`, MSVC C++ Build Tools/VCTools, LLVM clang, and an `nvcc -ccbin` smoke compile),
  builds the generated CUDA worker with host `nvcc`, and connects to the cluster web service through a
  local-only NodePort.

The browser e2e specification asserts backend metadata and Float32 results returned by the daemon, so an
in-process fallback cannot satisfy the CUDA lane. Live lane execution remains an open phase gate. See
[accelerator_daemon](../engineering/accelerator_daemon.md).
