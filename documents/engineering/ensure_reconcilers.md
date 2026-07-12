# Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [prerequisites](prerequisites.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [resource_budgeting](resource_budgeting.md), [wsl2](wsl2.md), [accelerator_daemon](accelerator_daemon.md)

> **Purpose**: Define the `ensure` reconciler contract — idempotent host-dependency reconcilers that
> the lift chain invokes as `ensure-X` steps inside `project up`, install-and-verify, and fail fast on
> the wrong host.

## TL;DR

- **A reconciler exists so a frame is never blocked by a host dependency that simply isn't installed.**
  Each host dependency is an idempotent reconciler that **installs** it when absent and is a verified
  no-op when present (install-and-verify) — an absent-but-installable dependency is installed, not a
  hard stop.
- **Reconcilers run as `ensure-X` chain steps inside `project up`.** They are core-shipped step kinds
  the lift chain (`chain :: cfg -> [Step]`) sequences alongside `deploy-VM`, `copy-source`,
  `build-pb`, and the project's own steps. The chain is the project; a reconciler is one kind of step
  in it. See [composition_methodology](../architecture/composition_methodology.md), the canonical home
  of the model.
- **`ensure` is not a command.** There is no top-level or hidden `ensure <tool>` verb. The command
  surface remains exactly `project`, `test`, `service`, `context`, and `check-code`; the reconcilers are
  library primitives that projects compose into their chains.
- **Provider reconcilers reach "usable", not merely "installed".** `ensure docker` and `ensure incus`
  converge to a frame that has the substrate capability the next chain step needs (a reachable Docker
  daemon / a VM-capable Incus) **and** working egress, so a `build-pb`, `build-image`, or `deploy-VM`
  step that follows can actually run.
- The Python wrapper's host minimums are the **pre-binary** hard fail-fast surface (the irreducible
  host floor it cannot install; see [prerequisites](prerequisites.md)). Everything else
  (Docker, Incus, the NVIDIA container toolkit, …) is installed by a reconciler when its step runs, so an
  absent-but-installable dependency is installed rather than a hard stop. A reconciler still has **two**
  hard fail-fast classes of its own: (1) a **wrong-host misuse** (e.g. an `ensure-cudawin` step reached
  on linux-cpu) — an operator error, not an absent dependency; and (2) an **absent, non-installable
  precondition on the correct host, or a dependency still missing after the install plan runs** — e.g.
  GPU reconcilers reject a substrate that lacks the `nvidia-smi` visibility needed to classify it as a
  GPU host, `ensure homebrew` dies when `brew` is
  absent on Apple, `ensure wsl2` dies on disabled firmware virtualization or a reboot-required state, and
  `installAndVerify` dies when the dependency is still not satisfied after the install plan.

## Reconciler Contract

A reconciler is a value, not a free function, and carries two parts:

- a **host-applicability predicate** over the detected substrate (`apple-silicon`, `linux-cpu`,
  `linux-gpu`, `windows-cpu`, `windows-gpu`); and
- a **reconcile action** that brings the host to the desired state and is safe to re-run.

Idempotence is required: running a reconciler when the host is already in the desired state is a
successful no-op. A **missing but installable** dependency is **never** a hard stop for the frame — the
reconcile action installs it (see *Install-and-Verify* below). A reconciler nonetheless fails fast in
two cases. First, running a reconciler on a host where the applicability predicate is false is a
fail-fast error, not a quiet skip — this surfaces operator mistakes (for example, an `ensure-cudawin`
step reached on linux-cpu) instead of hiding them. Second, an **absent, non-installable precondition on
the correct host** — or a dependency still missing after the install plan runs — is also a hard stop:
the GPU reconcilers reject a host without `nvidia-smi` visibility (the NVIDIA driver is a substrate
precondition, not auto-installed), `ensure homebrew` dies when `brew` is absent on Apple (its install plan is always
`Left`), `ensure wsl2` dies on disabled firmware virtualization or a reboot-required state, and
`installAndVerify` dies when its re-verify probe shows the dependency is still not satisfied after the
install plan. The wrong-host case is a misuse signal; the second case is a genuine absent-precondition
signal. The other hard prerequisites in the system are the Python wrapper's host minimums (see
[prerequisites](prerequisites.md)).

Reconcilers live under `HostBootstrap.Ensure.*`. Every external tool a reconciler drives is resolved
through the closed `HostTool` enumeration to an absolute path. The reconcile action itself stays
context-agnostic (`HostConfig -> IO ()`): a reconciler is converged "locally" in whatever frame its
chain step runs, unaware of the enclosing lift — exactly the context-agnostic shape the self-reference
lift requires (see [composition_methodology](../architecture/composition_methodology.md)).

## Reconcilers As Chain Steps

The lift chain is the project's identity. `project up` recursively interprets `chain projectCfg :: [Step]`
from the current frame; an `ensure-X` step is the chain's request to converge dependency `X` in the
frame it is reached in, before the steps that depend on it run. A descent's reconcilers therefore run
in dependency order *inside* the frame: a metal frame converges its VM provider before `deploy-VM`; a
VM frame converges GHC before `build-pb` and Docker before `build-image`.

Because a reconciler is idempotent, re-running `project up` re-converges every `ensure-X` step as a
verified no-op — reconcile-to-running is the lifecycle, not a one-shot install. The project chain is the
supported install and diagnostic surface for host dependencies.

- **WRONG**: a runbook tells an operator to converge a host by hand-running `ensure docker`,
  `ensure incus`, … in sequence as the supported install path. This is wrong because those commands are
  not part of the supported CLI and because the dependency order belongs in the chain.
- **RIGHT**: the operator runs `project up`; the chain reaches each `ensure-X` step in the right frame
  in the right order.

## Install-and-Verify

A reconcile action **installs** the dependency when it is absent and is a verified no-op when it is
present (install-and-verify, not check-only). The shared driver `installAndVerify` in
`HostBootstrap.Ensure` implements the probe-first loop:

1. **probe** the host; if the dependency is already satisfied, print a no-op line and stop;
2. otherwise run the **substrate-branched install plan** — a list of `InstallStep` values, each a
   resolved `HostTool` plus arguments;
3. **re-verify** with the same probe and fail fast with a one-line diagnostic if the dependency is
   still missing.

Tools are re-resolved after each step, so a freshly installed tool (for example `ghcup` just laid
down by `brew`) is discoverable by the next step. Homebrew formula steps are written as plain
`brew install <formula>` commands; Homebrew's installed-formula no-op behavior is the idempotent
path. The install plan is a **pure** function of the substrate — Homebrew formulae on
`apple-silicon`; `apt-get`/`ghcup`/the NVIDIA container toolkit on Linux — so it is unit-tested
without invoking the package manager (`winget` packages back the Windows install plans); the IO driver
is exercised during real bootstrap runs.

| Reconciler | Probe ("usable") | Install plan (per substrate) |
|------------|------------------|------------------------------|
| `docker` | `docker info` reachable **and** the invoking user can reach the socket (usable, not just installed) | Linux: `apt-get install -y docker.io acl` + enable the daemon + add the invoking user to `docker`, verify with `sg docker -c "docker info"`, and apply a per-user ACL to `/var/run/docker.sock` when the current process has not observed refreshed groups yet. Apple: defer to `ensure colima`. |
| `colima` | installed and `colima status` running | Apple: `brew install colima` + `colima start`. |
| `lima` | `limactl` resolved | Apple: `brew install lima`. |
| `cuda` | `nvidia-smi -L` reports a GPU and Docker's official nvkind volume-mount smoke (`/dev/null:/var/run/nvidia-container-devices/all`) sees that GPU | linux-gpu: install `nvidia-container-toolkit`; configure the NVIDIA runtime as Docker's default with CDI; enable `accept-nvidia-visible-devices-as-volume-mounts`; restart Docker. The kernel driver is a substrate precondition, not auto-installed. |
| `homebrew` | `brew` resolved | Apple: none — Homebrew is the toolchain root the Python bootstrapper installs pre-binary; an absent `brew` fails fast with the install instruction. |
| `ghc` | host `ghc` resolved | Apple: `brew install ghcup` + `ghcup install ghc`. |
| `cudawin` | `nvcc -V` resolves, `vswhere` finds VCTools, `clang` resolves, the NVIDIA driver reports a GPU, and an `nvcc -ccbin <MSVC>` smoke artifact compiles | windows-gpu: unattended `winget install` of the CUDA Toolkit (`Nvidia.CUDA`), MSVC C++ Build Tools/VCTools (`Microsoft.VisualStudio.2022.BuildTools`), and LLVM (`LLVM.LLVM`); the NVIDIA Windows driver is a substrate precondition, not auto-installed. |
| `wsl2` | firmware virtualization is present, the Windows hypervisor can launch, and WSL2 platform readiness is usable | windows: install `Microsoft.WSL`, enable WSL2 + Virtual Machine Platform (`wsl --install --no-distribution`), ensure Windows hypervisor launch readiness (`hypervisorlaunchtype auto` or equivalent verified state), and set default WSL version 2; feature or boot-state changes return `NeedsReboot`. A project-owned `deploy-VM` step registers that project's own named Ubuntu-24.04 distro. |
| `incus` | VM-capable **and** reachable (usable): Apple: `colima status incus` and `incus list` succeed. Linux: host `incus` resolved after daemon initialization. | Apple: `brew install incus`, `brew install colima`, `colima start incus --runtime incus`. Linux: `apt-get install -y incus` + `sudo incus admin init --minimal` + add the invoking user to `incus-admin`. |

## Provider Reconcilers Reach "Usable"

A provider reconciler is not done when the package is on disk — it is done when the next chain step can
use the frame. "Usable" means substrate capability **plus** working egress:

- **`ensure docker`** converges to a **reachable** Docker daemon the invoking user can drive — on
  Linux this is the socket-group / immediate-ACL grant, on Apple the per-project Colima VM started and
  verified — so the `build-image` step that follows can actually build. Installing the package without
  the socket reachable would leave the frame unusable.
- **`ensure incus`** converges to a **VM-capable, reachable** Incus — the daemon initialized on Linux,
  or the Colima-backed Incus provider started on Apple — so the `deploy-VM` step that follows can
  launch the pristine VM. See [incus](incus.md) and [lima](lima.md) for the provider details, and
  [cluster_lifecycle](cluster_lifecycle.md) for the cluster steps that run once the VM frame is up.

The provider frame's **egress** matters because the next steps pull base images and warm-store inputs
over the network; a provider that is installed but cannot reach Docker Hub is not "usable" for a
`build-image` or `deploy-kind` step. The Docker Hub credential the host frame holds is forwarded down
the lift so authenticated pulls work in nested frames (see
[composition_methodology](../architecture/composition_methodology.md)); the reconciler's job is to
leave the substrate reachable, the lift's job is to carry the credential.

## Reconciler Inventory

| Reconciler step | Applies to | Fail-fast behavior on wrong host |
|-----------------|------------|----------------------------------|
| `ensure-docker` | all substrates | n/a (Docker is required to build and run the project container; the step installs Docker and grants the invoking user a usable, reachable daemon — an immediate socket ACL for the current session when needed (Linux), or the per-project Colima VM (Apple) — and verifies the daemon is reachable). On Apple it also implies the per-project Colima VM exists. |
| `ensure-colima` | `apple-silicon` | Errors on Linux: Colima is the macOS Docker substrate; Linux uses native Docker. |
| `ensure-lima` | `apple-silicon` | Errors on Linux: Lima is the macOS VM provider used by the demo pristine Linux VM; Linux uses native Incus for the demo VM. |
| `ensure-apple-metal` | `apple-silicon` | Errors off Apple Silicon: verifies a visible Metal device, the macOS SDK through `xcrun`, and a Swift + Metal compile/run probe for the host-native accelerator daemon. It has no meaning in a Linux daemon pod or on Windows. |
| `ensure-cuda` | `linux-gpu` | Errors on `linux-cpu` and `apple-silicon`: no NVIDIA GPU substrate present. |
| `ensure-homebrew` | `apple-silicon` | Errors on Linux: Homebrew is the macOS host package manager for the host toolchain; it is the toolchain root the Python bootstrapper installs pre-binary, so the step verifies its presence and fails fast with the install instruction when it is absent. |
| `ensure-ghc` | `apple-silicon` | Errors on Linux: reconciles the Apple host GHC toolchain. The host build toolchain itself is ensured pre-binary by the bootstrapper, since every substrate builds host-native. |
| `ensure-cudawin` | `windows-gpu` | Errors on `windows-cpu`, `linux-*`, and `apple-silicon`: readies the Windows host CUDA build stack (driver + CUDA Toolkit + MSVC VCTools + LLVM clang) for the headless host build and compiles a CUDA smoke artifact through `nvcc -ccbin <MSVC>`; it has no meaning off a Windows GPU host. |
| `ensure-wsl2` | `windows-cpu` and `windows-gpu` | Errors off Windows: enables WSL/VMP and reconciles Windows hypervisor launch readiness. A separate project-owned `deploy-VM` step registers that project's own named `Ubuntu-24.04` distro that is the Windows VM frame, peer of Lima/Incus. See [wsl2](wsl2.md). |
| `ensure-incus` | `apple-silicon` and `linux` | Applies on both: `appliesTo = isAppleSilicon || isLinux`. On Apple it starts the Colima-backed Incus provider; on Linux it initializes the native daemon. See [incus](incus.md). |

`ensure-incus` is the **first cross-substrate reconciler** — its applicability predicate spans both
apple-silicon and linux (`appliesTo = isAppleSilicon || isLinux`), where every other reconciler above
applies to a single substrate family.

The `ensure-colima` / `ensure-ghc` / `ensure-homebrew` reconcilers on Apple silicon are exactly the
pre-binary host setup the thin Python bootstrapper drives before the build; see
[python_haskell_boundary](../architecture/python_haskell_boundary.md). `ensure-cuda` aligns with the
GPU host requirements tracked in [prerequisites](prerequisites.md).

## Accelerator Build-Stack Ensures

The accelerator-daemon demo extended the ensure surface for host-resident accelerator build stacks. The
Apple Silicon smoke run closed 2026-07-10 on an M1 Max host (`ensure apple-metal: present (no-op)`), and
the Windows GPU smoke closed the same day on an RTX 3090 host after CUDA 13.3, LLVM, and the
`vswhere`-resolved VCTools compiler built the `nvcc -ccbin` smoke artifact. These reconcilers run only on
host-daemon lanes; Linux daemon pods trust the base image and never run ensure from inside the container.

Phase 3 was temporarily reopened 2026-07-11 for the separate Linux GPU runtime contract. The direct
Linux GPU metal step runs `ensure cuda` before entering the project container. It now converges the exact
default-runtime/CDI/volume-mount settings consumed by nvkind and verifies them with the official
volume-mount smoke; only its Linux GPU real-host no-op gate remains open.

Phase 2 supplies the closed host-tool surface these reconcilers consume: `Swiftc`, `Xcrun`, and
`SystemProfiler` for Apple Silicon, `Clangxx` for the Linux CPU worker, and `NvidiaSmi`, `Nvcc`, `Clang`,
`MsvcCl`, and `Vswhere` for Windows GPU.

| Reconciler step | Applies to | Contract |
|-----------------|------------|------------------|
| `ensure-apple-metal` | `apple-silicon` | Verify a visible Metal device, `xcrun --sdk macosx --show-sdk-path`, and a Swift compiler that can build and run a tiny Swift + Metal probe headlessly. The pre-binary floor already requires Xcode Command Line Tools and Homebrew; full Xcode, Tart, keychain state, and a VM are out of contract. |
| hardened `ensure-cudawin` | `windows-gpu` | Keep the NVIDIA driver as a precondition, install/verify CUDA Toolkit (`Nvidia.CUDA`) with `winget`, Visual Studio Build Tools with the C++ workload for `nvcc`'s host compiler, and LLVM clang (`LLVM.LLVM`), then compile a CUDA smoke artifact through the resolved MSVC host compiler path. |

The Apple reconciler is new Phase-3 code. The Windows work hardens the existing `ensure-cudawin`
reconciler rather than adding a second Windows accelerator reconciler, because the demo's Windows
accelerator lane is CUDA. Static validation is green (`cabal build all --ghc-options=-Werror` and
`cabal test all --ghc-options=-Werror`, 340 core tests on 2026-07-11); both Apple Silicon and Windows GPU
real smoke gates are closed.

## Diagnostics

A wrong-host run emits a single diagnostic line naming the reconciler, the detected substrate, and
the substrate it requires, then exits non-zero. Reconcilers do not attempt partial work before
failing the applicability check. The applicability decision is the pure `decide` function in
`HostBootstrap.Ensure`; `runReconciler` is the IO wrapper that performs the stderr write and the
non-zero exit, so the decision is testable without exiting the process. When a reconciler runs as an
`ensure-X` chain step, the same fail-fast surfaces as a non-zero step result and aborts `project up`.

- **WRONG**: a reconciler reached on a non-applicable substrate prints nothing and exits `0`. This is
  wrong because it masks an operator error and lets a build proceed against an environment that cannot
  satisfy it.
- **RIGHT**: the reconciler prints `ensure cudawin: not applicable on linux-cpu (requires windows-gpu)`
  and exits non-zero when the `ensure-cudawin` chain step is reached on the wrong substrate.

## One Invocation Surface

The reconcilers carry a single contract — install-and-verify, idempotence, wrong-host fail-fast, and
provider reconcilers reaching "usable" — and the system reaches that contract through `ensure-X` chain
steps. The recursive `project up` interpreter walks `chain cfg :: [Step]` and converges each dependency in
the frame its step is reached in, sequenced alongside the other core and project step kinds
(`deploy-VM`, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`,
`expose-port`).

The concrete reconciler set is still centralized as `allReconcilers` (the `docker`, `colima`,
`apple-metal`, `cuda`, `cudawin`, `homebrew`, `ghc`, `lima`, `wsl2`, and cross-substrate `incus`
reconcilers), and project-owned actions can call `runEnsure` directly when they need one reconciler in a
specific scripted seam. That remains a library call, not a surfaced command.

## Current Status

The Apple Silicon, Linux, and Windows reconciler inventory above is implemented and unit-validated.
Windows substrate detection and the current `ensure-cudawin` surface are closed in phases 2 and 3. The
Windows VM-provider reconciler `ensure-wsl2` is implemented and closed in Phase 11 (2026-07-01): the
OS-level hypervisor-launch readiness branch and the real WSL2 provider lifecycle run both landed (`test run
all` `6/6` -> `project destroy`). The former `ensure-tart` reconciler is dropped from this contract and
tracked as removed in [legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

The accelerator build-stack reconcilers are implemented, statically validated, and real-run-validated on
Apple Silicon and Windows GPU. Reopened Phase 3 stays `Active` only until the tightened Linux `ensure
cuda` contract reports `present (no-op)` on a Linux GPU Docker host; its static plan/probe coverage and
340-test core gate passed 2026-07-11.
