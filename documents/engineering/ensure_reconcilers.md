# Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [prerequisites](prerequisites.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [resource_budgeting](resource_budgeting.md), [wsl2](wsl2.md), [accelerator_daemon](accelerator_daemon.md)

> **Purpose**: Define the target `ensure` reconciler contract, document the strength and platform
> limits of current probes/install plans, and explain how current project actions invoke the library.

## TL;DR

- **A reconciler separates absence from unsupported/non-installable state.** When a supported install
  plan exists for the current substrate, it installs after an absent result and re-runs the probe.
  Delegated or non-installable prerequisites fail with a reason. The no-op guarantee is only as strong
  as the probe: several probes establish real usability, while weak presence-only probes remain open
  defects.
- **Reconcilers are library values invoked while `project up` executes.** Core exports
  `ensureStep`, but the current demo does not use it: provider/build/accelerator actions call
  `runEnsure` directly, and the pristine VM bootstrap installs GHC/Docker through one composite shell
  action. The target plan represents every reconcile effect as its own typed operation with a retained
  outcome. See [composition_methodology](../architecture/composition_methodology.md).
- **`ensure` is not a command.** There is no top-level or hidden `ensure <tool>` verb. The command
  surface remains exactly `project`, `test`, `service`, `context`, and `check-code`; the reconcilers are
  library primitives that projects compose into their chains.
- **Incus readiness is a total capability observation.** Its final probe distinguishes missing client,
  absent/permission-denied/unreachable daemon, missing VM capability, missing image-server egress, and
  ready. Only ready mints the opaque `IncusProviderCapability`. Other reconcilers still vary in probe
  strength, and the universal plan-owned prepared-operation integration remains target work.
- The Python wrapper's host minimums are the **pre-binary** hard fail-fast surface (the irreducible
  host floor it cannot install; see [prerequisites](prerequisites.md)). Everything else
  (where a substrate-specific install plan exists) is installed by a reconciler when its action runs, so
  an absent-but-installable dependency is installed rather than a hard stop. Docker's install plan exists
  only on Linux; Apple and Windows delegate that daemon to other provider paths, and Homebrew is
  verification-only. A reconciler still has **two**
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

Idempotence is the target contract: running a reconciler when the host is already in the desired state
must be a successful, verified no-op. The shared driver is probe-first, and the strongest reconcilers
add a final capability observation after remediation. A
**missing dependency with a supported install plan on that substrate** is not a hard stop merely because
it is absent — the reconcile action installs it when its probe reports absence (see
*Install-and-Verify* below). A reconciler nonetheless
fails fast in two cases. First, running a reconciler on a host where the applicability predicate is false is a
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
through the closed `HostTool` enumeration to an absolute path. The current reconcile action is
context-agnostic (`HostConfig -> IO ()`): it runs locally in whatever frame its invoking action reaches.
The target preserves that local interpretation while replacing `IO ()` with the indexed
`ReconcileResult`/failure algebra in
[lifecycle_state_model](../architecture/lifecycle_state_model.md), so a successful transition carries
the exact observation or receipt the dependent operation consumes.

## Current Invocation And Target Plan Operations

The lift chain is the project's identity. Current `project up` interprets the exact current-frame segment
of `chain projectCfg :: [Step]`; target recursive traversal authenticates each child entry.
`HostBootstrap.Step.ensureStep` can represent a reconcile action as a named row,
but the current demo does not assemble its chain that way:

- `deploy-VM` actions call the selected provider reconciler;
- the Linux-GPU direct bootstrap calls Docker and CUDA reconcilers inside its `build-image` action;
- host accelerator startup calls Apple Metal or Windows CUDA reconciliation inside the post-handoff
  action; and
- the VM pristine-bootstrap action installs GHC and Docker directly in one larger guest script rather
  than calling the Haskell reconcilers.

Re-running `project up` therefore re-enters those composite actions, which in turn re-run some probes or
package-manager no-op paths. It is not accurate to infer an independently ordered `ensure-*` row or
retained readiness result for each dependency from the dry-run chain. The target plan makes each
reconcile operation explicit, sequences it before exact dependants, and exposes only a verified,
resource-indexed result.

- **WRONG**: a runbook tells an operator to converge a host by hand-running `ensure docker`,
  `ensure incus`, … in sequence as the supported install path. This is wrong because those commands are
  not part of the supported CLI and because the dependency order belongs in the chain.
- **RIGHT (current operator surface)**: the operator runs `project up`; its registered composite actions
  invoke the reconcilers/install steps they currently own.
- **RIGHT (target representation)**: the opaque plan contains a distinct reconcile node for each
  dependency, and dependent operations require that node's retained result.

## Install-and-Verify

A reconcile action takes a no-op path when its probe reports presence and, when a plan exists,
**installs** the dependency after an absent result. The shared driver `installAndVerify` in
`HostBootstrap.Ensure` implements the probe-first loop:

1. **probe** the host; if the dependency is already satisfied, print a no-op line and stop;
2. otherwise resolve the **substrate-branched install plan** — either an explicit refusal for a
   non-installable prerequisite or a list of `InstallStep` values, each a resolved `HostTool` plus
   arguments;
3. **re-run the same probe** and fail fast with a one-line diagnostic if it is still unsatisfied.

This is install-and-reprobe mechanically. It is install-and-**verify** semantically only to the extent
that the probe proves the desired state. Docker's daemon probe is a capability check. Incus goes further:
after client convergence it performs one total provider observation and only the fully usable branch
mints an opaque capability. The target operation algebra still retains such observations as scoped
reconcile outcomes rather than returning `IO ()`.

Tools are re-resolved after each step, so a freshly installed tool (for example `ghcup` just laid
down by `brew`) is discoverable by the next step. Homebrew formula steps are written as plain
`brew install <formula>` commands; Homebrew's installed-formula no-op behavior is the idempotent
path. The install plan is a **pure** function of the substrate — Homebrew formulae on
`apple-silicon`; `apt-get`/`ghcup`/the NVIDIA container toolkit on Linux — so it is unit-tested
without invoking the package manager (`winget` packages back the Windows install plans); the IO driver
is exercised during real bootstrap runs.

| Reconciler | Current probe | Install plan (per substrate) |
|------------|------------------|------------------------------|
| `docker` | `docker info` reachable; on Linux the follow-up also establishes invoking-user socket access | Linux only: `apt-get install -y docker.io acl` + enable the daemon + add the invoking user to `docker`, verify with `sg docker -c "docker info"`, and apply a per-user ACL to `/var/run/docker.sock` when needed. On Apple config-free setup is refused because the prepared project Colima wall owns Docker; on Windows it is delegated to the WSL2/provider path. |
| `lima` | `limactl` resolved | Apple: `brew install lima`. |
| `cuda` | `nvidia-smi -L` reports a GPU and Docker's official nvkind volume-mount smoke (`/dev/null:/var/run/nvidia-container-devices/all`) sees that GPU | linux-gpu: install `nvidia-container-toolkit`; configure the NVIDIA runtime as Docker's default with CDI; enable `accept-nvidia-visible-devices-as-volume-mounts`; restart Docker. The kernel driver is a substrate precondition, not auto-installed. |
| `homebrew` | `brew` resolved | Apple: none — Homebrew is an independently installed host minimum asserted by the Python bootstrapper; an absent `brew` fails fast with the install instruction. |
| `ghc` | host `ghc` resolved | Apple: `brew install ghcup` + `ghcup install ghc`. |
| `cudawin` | `nvcc -V` resolves, `vswhere` finds VCTools, `clang` resolves, the NVIDIA driver reports a GPU, and an `nvcc -ccbin <MSVC>` smoke artifact compiles | windows-gpu: unattended `winget install` of the CUDA Toolkit (`Nvidia.CUDA`), MSVC C++ Build Tools/VCTools (`Microsoft.VisualStudio.2022.BuildTools`), and LLVM (`LLVM.LLVM`); the NVIDIA Windows driver is a substrate precondition, not auto-installed. |
| `wsl2` | `wsl --status` reports usable platform state, or the online-distribution list is reachable and includes Ubuntu 24.04; when that probe fails, separate firmware and hypervisor checks classify the failure before installation | windows: install `Microsoft.WSL`, enable WSL2 + Virtual Machine Platform (`wsl --install --no-distribution`), ensure Windows hypervisor launch readiness, and set default WSL version 2; a required reboot exits with an explicit diagnostic. A project-owned `deploy-VM` step registers that project's own named Ubuntu-24.04 distro. |
| `incus` | Total final status distinguishes missing client, absent/permission-denied/unreachable daemon, missing KVM/QEMU/OVMF VM capability, missing `images:` egress, and ready; only ready mints `IncusProviderCapability` | Apple: `brew install incus`, `brew install colima`, `colima start incus --runtime incus`, then final provider/profile/egress probe. Linux: install `incus` + `acl`, initialize/restart the daemon when absent, grant `incus-admin` and immediate socket access, install QEMU/OVMF, preserve `incusbr0` forwarding through `DOCKER-USER`, then run the same final capability/egress classification. |

## Current Provider Probes And Target Usability

The target contract does not call a provider ready merely because its package is on disk. It requires the
capability the dependent operation consumes and, where subsequent work pulls remote inputs, working
egress. Current Incus code implements that provider observation, while general lifecycle integration
still returns a result-free reconciler action:

- **`ensure docker`** checks that the invoking process can reach the Docker daemon. On Linux the install
  path also grants socket access through group membership and an immediate ACL. On Apple a missing
  daemon is refused at this config-free seam: the plan-bound Colima adapter observes/reconciles the
  exact project profile and routes Docker through its named context.
- **Prepared Colima wall** is deliberately not a `Reconciler` row. It requires a validated binary
  context, lifecycle plan, admitted exact wall, partition, and journal-before-call reservation. It
  installs the Colima tool when absent, but never probes or starts the shared `default` profile.
- **`ensure incus` on Apple and Linux** converges its substrate-specific provider, then probes daemon
  reachability, VM capability, and `images:ubuntu/24.04` metadata egress. Permission, absence,
  reachability, VM capability, and egress failures remain distinct typed statuses; only ready enters the
  opaque capability continuation. See [incus](incus.md) and [cluster_lifecycle](cluster_lifecycle.md).

Egress still matters because later steps pull base images and warm-store inputs; forwarding a Docker Hub
credential down the lift supplies authentication but does not prove network reachability. Incus now
checks its image-server route, but other provider/dependent routes must retain their own exact
observations. See
[composition_methodology](../architecture/composition_methodology.md) for credential forwarding and
[lifecycle_state_model](../architecture/lifecycle_state_model.md) for the target typed observation.

## Reconciler Inventory

| Reconciler step | Applies to | Fail-fast behavior on wrong host |
|-----------------|------------|----------------------------------|
| `ensure-docker` | applicability predicate accepts all substrates | It installs/grants access only on Linux. On Apple, absence refuses because Docker belongs to the prepared project Colima wall; on Windows, absence refuses because Docker belongs to the WSL2/provider path. A reachable pre-existing daemon is accepted. It does not verify egress. |
| `ensure-lima` | `apple-silicon` | Errors on Linux: Lima is the macOS VM provider used by the demo pristine Linux VM; Linux uses native Incus for the demo VM. |
| `ensure-apple-metal` | `apple-silicon` | Errors off Apple Silicon: verifies a visible Metal device, the macOS SDK through `xcrun`, and a Swift + Metal compile/run probe for the host-native accelerator daemon. It has no meaning in a Linux daemon pod or on Windows. |
| `ensure-cuda` | `linux-gpu` | Errors on `linux-cpu` and `apple-silicon`: no NVIDIA GPU substrate present. |
| `ensure-homebrew` | `apple-silicon` | Errors on Linux: Homebrew is the macOS host package manager and an independently installed host minimum; the step verifies its presence and fails fast with the install instruction when it is absent. |
| `ensure-ghc` | `apple-silicon` | Errors on Linux: reconciles the Apple host GHC toolchain. The host build toolchain itself is ensured pre-binary by the bootstrapper, since every substrate builds host-native. |
| `ensure-cudawin` | `windows-gpu` | Errors on `windows-cpu`, `linux-*`, and `apple-silicon`: verifies the non-installable NVIDIA driver/GPU prerequisite, reconciles CUDA Toolkit + MSVC VCTools + LLVM clang for the headless host build, and compiles a CUDA smoke artifact through `nvcc -ccbin <MSVC>`; it has no meaning off a Windows GPU host. |
| `ensure-wsl2` | `windows-cpu` and `windows-gpu` | Errors off Windows: enables WSL/VMP and reconciles Windows hypervisor launch readiness. A separate project-owned `deploy-VM` step registers that project's own named `Ubuntu-24.04` distro that is the Windows VM frame, peer of Lima/Incus. See [wsl2](wsl2.md). |
| `ensure-incus` | `apple-silicon` and `linux` | Applies on both: `appliesTo = isAppleSilicon || isLinux`. It converges the substrate-specific provider and requires the total final daemon/permission/VM-capability/egress status to be ready. See [incus](incus.md). |

`ensure-incus` has an explicit Apple-or-Linux predicate
(`appliesTo = isAppleSilicon || isLinux`). It is not the first/only cross-substrate predicate:
`ensure-docker` currently declares `appliesTo = const True`, even though its absent-daemon install plan
is Linux-only and delegates/refuses elsewhere.

The Python bootstrapper asserts Homebrew and uses it to establish the host-native Haskell build
toolchain before a project binary exists. It does not install Homebrew and does not drive the Colima
runtime step. The built Haskell project owns the prepared Colima provider adapter and the other runtime
reconcilers; recursive command-plan integration remains tracked in the development plan. See
[python_haskell_boundary](../architecture/python_haskell_boundary.md).
`ensure-cuda` aligns with the GPU host requirements tracked in [prerequisites](prerequisites.md).

## Accelerator Build-Stack Ensures

The accelerator-daemon demo extends the ensure surface for host-resident accelerator build stacks.
These reconcilers run only on host-daemon lanes; Linux daemon pods trust the base image and never run
ensure from inside the container. Hardware evidence and closure status belong in the development plan.

The direct Linux GPU metal step runs `ensure cuda` before entering the project container. It converges
the default-runtime/CDI/volume-mount settings consumed by nvkind and verifies them with the official
volume-mount smoke. Whether a particular native or virtualized host has passed the hardware gate is
plan-owned evidence, not part of this stable contract.

The closed host-tool surface these reconcilers consume includes `Swiftc`, `Xcrun`, and
`SystemProfiler` for Apple Silicon, `Clangxx` for the Linux CPU worker, and `NvidiaSmi`, `Nvcc`, `Clang`,
`MsvcCl`, and `Vswhere` for Windows GPU.

| Reconciler step | Applies to | Contract |
|-----------------|------------|------------------|
| `ensure-apple-metal` | `apple-silicon` | Verify a visible Metal device, `xcrun --sdk macosx --show-sdk-path`, and a Swift compiler that can build and run a tiny Swift + Metal probe headlessly. The pre-binary floor already requires Xcode Command Line Tools and Homebrew; full Xcode, Tart, keychain state, and a VM are out of contract. |
| hardened `ensure-cudawin` | `windows-gpu` | Keep the NVIDIA driver as a precondition, install/verify CUDA Toolkit (`Nvidia.CUDA`) with `winget`, Visual Studio Build Tools with the C++ workload for `nvcc`'s host compiler, and LLVM clang (`LLVM.LLVM`), then compile a CUDA smoke artifact through the resolved MSVC host compiler path. |

The Windows path uses the existing `ensure-cudawin`
reconciler rather than adding a second Windows accelerator reconciler, because the demo's Windows
accelerator lane is CUDA. Static and hardware gate status changes over time and are recorded in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md), not here.

## Diagnostics

A wrong-host run emits a single diagnostic line naming the reconciler, the detected substrate, and
the substrate it requires, then exits non-zero. Reconcilers do not attempt partial work before
failing the applicability check. The applicability decision is the pure `decide` function in
`HostBootstrap.Ensure`; `runReconciler` is the IO wrapper that performs the stderr write and the
non-zero exit, so the decision is testable without exiting the process. When a reconciler is registered
through `ensureStep`, the same fail-fast surfaces as a non-zero step result; in the current demo its
exception instead aborts the enclosing composite action and therefore `project up`.

- **WRONG**: a reconciler reached on a non-applicable substrate prints nothing and exits `0`. This is
  wrong because it masks an operator error and lets a build proceed against an environment that cannot
  satisfy it.
- **RIGHT**: the reconciler prints `ensure cudawin: not applicable on linux-cpu (requires windows-gpu)`
  and exits non-zero when its invoking lifecycle action reaches it on the wrong substrate.

## One Invocation Surface

The reconcilers are intended to carry one contract — install-and-verify, idempotence, wrong-host
fail-fast, and capability-level provider readiness. The current shared driver provides the
probe/install/reprobe structure, while the probe table above records where the implementation is weaker
than that target. Invocation is not yet one representation: current-frame Chain walks its projected
`chain cfg :: [Step]` segment, while target recursive `project up` continues through child frames; the demo
calls reconciler runners from composite actions and also duplicates
some guest installation as shell work.

The nine context-free reconcilers are centralized as `allReconcilers` (`docker`, `apple-metal`, `cuda`,
`cudawin`, `homebrew`, `ghc`, `lima`, `wsl2`, and cross-substrate `incus`). Project/config/plan-dependent
provider adapters cannot appear in that list: Colima now requires the prepared project wall rather than
a standalone `ensure-colima`. Project-owned actions can call `runEnsure` directly when they need a
context-free reconciler in a scripted seam. That remains a library call, not a surfaced command.

## Current Status

The Apple Silicon, Linux, and Windows reconciler inventory above is implemented and unit-covered. The
Windows VM-provider reconciler `ensure-wsl2` is implemented; current hardware/lifecycle closure belongs
in the development plan. The closed registry contains no `ensure-tart` member.

The accelerator build-stack reconcilers are implemented. Current static and hardware closure, including
native Linux `nvkind` and accelerator lifecycle validation, is owned by
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).
