# Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [prerequisites](prerequisites.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [composition_methodology](../architecture/composition_methodology.md), [composition_patterns](composition_patterns.md), [lima](lima.md), [wsl2](wsl2.md), [accelerator_daemon](accelerator_daemon.md)

> **Purpose**: Define the `ensure` reconciler contract, document the strength and platform
> limits of current probes/install plans, and explain how current project actions invoke the library.

## TL;DR

- **A reconciler separates absence from unsupported/non-installable state.** When a supported install
  plan exists for the current substrate, it installs after an absent result and re-runs the probe.
  Delegated or non-installable prerequisites fail with a reason. The no-op guarantee is only as strong
  as the probe: several probes establish real usability, while presence-only probes establish only presence and must not be described as usability checks.
- **Reconcilers are library values invoked while `project up` executes.** Core exports
  `ensureStep`, but the current demo does not use it: provider/build/accelerator actions call
  `runEnsure` directly, and the pristine VM bootstrap runs the typed guest bootstrap vocabulary (floor
  packages, pinned GHC, bootstrapper, build, install) and then installs Docker through a separate guest
  shell step that does not call the Haskell Docker reconciler. These local install helpers do not themselves return managed lifecycle authority;
  exact resource effects are prepared and settled by the surrounding admitted operation. See [composition_methodology](../architecture/composition_methodology.md).
- **`ensure` is not a command.** There is no top-level or hidden `ensure <tool>` verb. The command
  surface remains exactly `project`, `test`, `service`, `context`, and `check-code`; the reconcilers are
  library primitives that projects compose into their chains.
- **Incus readiness is a total capability observation.** Its final classification distinguishes missing
  client, a daemon listing that fails as absent, permission-denied, or unreachable, missing VM capability,
  missing image-server egress, and ready. Only the ready status mints the opaque `IncusProviderCapability`,
  but that status is an exported constructor a caller can build without the probe (see
  [Current Status](#current-status)). Other reconcilers still vary in probe strength, and prepared managed
  operations provide the separate exact lifecycle authority boundary.
- The Python wrapper's host minimums are the **pre-binary** hard fail-fast surface (the irreducible
  host floor it cannot install; see [prerequisites](prerequisites.md)). Everything else
  (where a substrate-specific install plan exists) is installed by a reconciler when its action runs, so
  an absent-but-installable dependency is installed rather than a hard stop. Docker's install plan exists
  only on Linux; Apple and Windows delegate that daemon to other provider paths, and Homebrew is
  verification-only. A reconciler still has **two**
  hard fail-fast classes of its own: (1) a **wrong-host misuse** (e.g. an `ensure-cudawin` step reached
  on linux-cpu) — an operator error, not an absent dependency; and (2) an **absent, non-installable
  precondition on the correct host, or a dependency still missing after the install plan runs** — e.g.
  a GPU reconciler on a host classified as a GPU host whose `nvidia-smi` is absent or lists no device
  (a host with no NVIDIA evidence at all is classified `linux-cpu` or `windows-cpu` and gets the class (1)
  wrong-host diagnostic instead), `ensure homebrew` dies when `brew` is
  absent on Apple, `ensure wsl2` dies on disabled firmware virtualization or a reboot-required state, and
  `installAndVerify` dies when the dependency is still not satisfied after the install plan.

## Reconciler Contract

A reconciler is a value, not a free function, and carries two parts:

- a **frame table** (`FrameTable`) — one row per host frame the reconciler is written for; and
- a **reconcile action** that brings the host to the desired state and is safe to re-run.

### The frame table

In this section and the inventory below, "frame" means the **host frame** (`HostFrame`, the outer-host
family), not the default topology sense; see the [glossary](../README.md#glossary). A reconciler's
`FrameTable` is keyed by host frame and is not the glossary's provider "frame table" sense. A reconciler is a
**row**, not a module of parallel logic. The host-frame axis is closed and has three
constructors — `LinuxFrame`, `AppleFrame`, `WindowsFrame` — and `substrateFrame` is the one place the five
classification tags (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) collapse onto
it, which is what makes `isLinux`, `isWindows`, and `isAppleSilicon` one derived fact rather than three
independently maintained ones. The accelerator is a **capability of a frame**, not a frame of its own: a row
that needs an NVIDIA device says so, and a table carrying both a general and an accelerator row for one frame
selects the specific one.

Three things a reader might expect to be separate fields are three views of the same rows, so they cannot
disagree:

- **whether the reconciler applies** — does the table have a row for this host;
- **what its diagnostic says it requires** — rendered from the rows themselves, so `ensure incus` reads
  `apple-silicon or linux` and `ensure docker` reads `all substrates` without either being written twice;
- **what it installs here** — the row's own plan.

A row's plan is either `InstallHere` (this host frame installs the dependency, with these steps) or
`ProvidedElsewhere` (the dependency is probed here but this host frame does not install it, and the row's
text names who does — Docker's apple-silicon row names the prepared per-project Colima adapter, which no
demo or production lifecycle step currently drives; see [Current Status](#current-status)). A host frame
the reconciler has **no** row for is
"not applicable", which is a decision rather than a refusal a caller has to read out of a failed install:
`ensure incus` has apple and linux rows and no Windows row at all, because the WSL2 provider path owns the
Windows host provider and stating that twice is how two answers to one question start to differ.

Outside this section and the inventory, an unqualified "frame" on this page (the guest frame, the VM frame,
whatever frame an invoking action reaches) is the default topology sense.

The probe-first idempotence contract is: running a reconciler when the host is already in the desired state
must be a successful, verified no-op. The shared driver is probe-first, and the strongest reconcilers
add a final capability observation after remediation. The Linux `ensure-incus` row does not yet meet the
no-op half of this contract: it re-runs package installs and restarts the daemon on every run (see
[Current Status](#current-status)). A
**missing dependency with a supported install plan on that substrate** is not a hard stop merely because
it is absent — the reconcile action installs it when its probe reports absence (see
*Install-and-Verify* below). A reconciler nonetheless
fails fast in two cases. First, running a reconciler on a host where the applicability predicate is false is a
fail-fast error, not a quiet skip — this surfaces operator mistakes (for example, an `ensure-cudawin`
step reached on linux-cpu) instead of hiding them. Second, an **absent, non-installable precondition on
the correct host** — or a dependency still missing after the install plan runs — is also a hard stop:
on a host classified as a GPU host, `ensure cuda` and `ensure cudawin` die when `nvidia-smi` is absent,
and `ensure cuda` also dies when `nvidia-smi -L` lists no device (`ensure cudawin` instead runs its plan
and fails the re-probe), because the NVIDIA driver is a substrate precondition, not auto-installed;
`ensure homebrew` dies when `brew` is absent on Apple (its install plan is always
`Left`), `ensure wsl2` dies on disabled firmware virtualization or a reboot-required state, and
`installAndVerify` dies when its re-verify probe shows the dependency is still not satisfied after the
install plan. The wrong-host case is a misuse signal; the second case is a genuine absent-precondition
signal. Which of the two a broken GPU driver produces depends on classification: both the bootstrapper
and the binary's own detection treat the NVIDIA kernel marker files (`/proc/driver/nvidia/version`,
`/dev/nvidiactl`) as sufficient and consult `nvidia-smi -L` only when neither exists, so a host with the
markers is a GPU host (class two on a failing listing) while a host with neither markers nor a listed
device is a CPU host (class one). The other hard prerequisites in the system are the Python wrapper's host minimums (see
[prerequisites](prerequisites.md)).

A reconciler is named in two spellings for one thing. `ensure <name>` (with `<name>` its
`reconcilerName`) is the prefix of every line it prints, including its diagnostics; `ensure-<name>` is the
chain-step label `ensureStep` gives it when a project registers it as a step. The inventory tables below
use the step label; neither spelling is a CLI command.

Reconcilers live under `HostBootstrap.Ensure.*`. The outer executable of every step and probe a
reconciler runs is a `HostTool` resolved to an absolute path. That guarantee covers the outer executable
only. Most Linux install steps resolve only `sudo` that way and pass bare program names (`apt-get`,
`systemctl`, `nvidia-ctk`, `incus`, `usermod`, `setfacl`) for the privileged process to resolve through its
own search path. A few steps hand a shell string to an interpreter: the CUDA repository setup
(`sudo /bin/sh -c`), the Incus VM-capability probe and `kvm` module load (`sudo sh -c`), the Incus
`DOCKER-USER` forwarding rule (`sudo bash -c`), the Docker group check (`sudo -u <user> sg docker -c`), and
the WSL2 firmware and hypervisor probes (`powershell -NoProfile -Command`). The Apple Metal and Windows CUDA
probes also run the smoke executable they just compiled. The current reconcile action is
context-agnostic (`HostConfig -> IO ()`): it runs locally in whatever frame its invoking action reaches.
Managed resource transitions have a separate indexed `ReconcileResult`/failure algebra in
[lifecycle_state_model](../architecture/lifecycle_state_model.md). Their prepared operation carries the
exact observation or receipt needed by a dependent operation; a local helper's `IO ()` completion cannot
stand in for that evidence.

## Invocation And Managed Plan Operations

The lift chain is the project's identity. The root coordinator interprets each exact current-frame
segment of the admitted plan and authenticates each recursive child entry.
`HostBootstrap.Step.ensureStep` can represent a reconcile action as a named row,
but the current demo does not assemble its chain that way:

- on the VM-backed lanes, the demo's own `ensure-vm-provider` step calls the Lima, Incus, or WSL2
  reconciler for the detected substrate;
- the Linux-GPU direct lane calls the Docker reconciler inside its `deploy-vm` action (which reserves the
  direct host provider) and the CUDA reconciler inside its `build-image` action;
- host accelerator startup calls Apple Metal or Windows CUDA reconciliation inside the post-handoff
  action; and
- the VM pristine-bootstrap action (the `build-pb` step) runs `runGuestBootstrap` over a
  `GuestBootstrapTarget` — floor packages, pinned GHC, bootstrapper, build, install; see
  [Guest Bootstrap Vocabulary](#guest-bootstrap-vocabulary) — and then installs Docker through a
  separate guest shell step that does not call the Haskell Docker reconciler.

Re-running `project up` therefore re-enters those composite actions, which in turn re-run some probes or
package-manager no-op paths. It is not accurate to infer an independently ordered `ensure-*` row or
retained readiness result for each dependency from the dry-run chain. Managed provider, share, cluster,
and workload operations separately retain their exact prepared authority, dependency observations, and
settlement results.

- **WRONG**: a runbook tells an operator to converge a host by hand-running `ensure docker`,
  `ensure incus`, … in sequence as the supported install path. This is wrong because those commands are
  not part of the supported CLI and because the dependency order belongs in the chain.
- **RIGHT (current operator surface)**: the operator runs `project up`; its registered composite actions
  invoke the reconcilers/install steps they currently own.
- **RIGHT (managed resource boundary)**: the opaque plan binds the resource operation and its complete
  dependency set; dependent managed operations freshly revalidate their retained dependency package.

## Install-and-Verify

A reconcile action takes a no-op path when its probe reports presence and, when a plan exists,
**installs** the dependency after an absent result. The shared driver `installAndVerify` in
`HostBootstrap.Ensure` implements the probe-first loop:

1. **probe** the host; if the dependency is already satisfied, print a no-op line and stop;
2. otherwise resolve the **substrate-branched install plan** — either an explicit refusal for a
   non-installable prerequisite (which fails fast with that refusal) or a list of `InstallStep` values,
   each a resolved `HostTool` plus arguments;
3. **run each step in order**; a non-zero exit fails fast naming the step, with two exceptions: a
   `winget install` whose output reports the package already installed (or no available upgrade) is
   accepted as success, and any `wsl` step whose output mentions a reboot or restart — or a
   `wsl --install` that exits `-1` — aborts with a reboot-required diagnostic;
4. **re-run the same probe** and fail fast with a one-line diagnostic if it is still unsatisfied.

This is install-and-reprobe mechanically. It is install-and-**verify** semantically only to the extent
that the probe proves the desired state. Docker's daemon probe is a capability check. Incus goes further:
after client convergence it performs one total provider observation and only the ready status mints an
opaque capability. That capability observation remains distinct from the scoped managed
settlement produced by the prepared operation algebra.

Tools are re-resolved after each step, so a freshly installed tool (for example `ghcup` just laid
down by `brew`) is discoverable by the next step. Homebrew formula steps are written as plain
`brew install <formula>` commands; Homebrew's installed-formula no-op behavior is the idempotent
path. The install plan is a **pure** function of the substrate — Homebrew formulae on
`apple-silicon`; `apt-get`/`ghcup`/the NVIDIA container toolkit on Linux — so it is unit-tested
without invoking the package manager (`winget` packages back the Windows install plans); the IO driver
is exercised during real bootstrap runs.

| Reconciler | Current probe | Install plan (per substrate) |
|------------|------------------|------------------------------|
| `docker` | `docker info` reachable and `docker buildx version` succeeds; on Linux the follow-up also establishes invoking-user socket access | Linux only: `apt-get install -y docker.io docker-buildx acl` + enable the daemon + add the invoking user to `docker`, verify with `sg docker -c "docker info"`, and apply a per-user ACL to `/var/run/docker.sock` when needed. On Apple an absent daemon is refused, naming the prepared per-project Colima adapter as its owner (an adapter no demo or production lifecycle step drives); on Windows it is delegated to the WSL2/provider path. |
| `apple-metal` | `system_profiler` reports a Metal device, `xcrun --sdk macosx --show-sdk-path` returns an SDK path, and a Swift + Metal smoke program compiles and runs | Apple: none — Swift, `xcrun`, the macOS SDK, and Metal come with the Xcode Command Line Tools; an unsatisfied probe fails fast with the `xcode-select --install` instruction. |
| `lima` | `limactl` resolved | Apple: `brew install lima`. |
| `cuda` | `nvidia-smi -L` reports a GPU and Docker's official nvkind volume-mount smoke (`/dev/null:/var/run/nvidia-container-devices/all`) sees that GPU | linux-gpu: install `nvidia-container-toolkit`; configure the NVIDIA runtime as Docker's default with CDI; enable `accept-nvidia-visible-devices-as-volume-mounts`; restart Docker. The kernel driver is a substrate precondition, not auto-installed. |
| `homebrew` | `brew` resolved | Apple: none — Homebrew is an independently installed host minimum asserted (not installed) by the Python bootstrapper; an absent `brew` fails fast with the row's instruction, which reads "Homebrew is the host toolchain root; the Python bootstrapper installs it pre-binary. Install from https://brew.sh and retry." Its middle clause is wrong (see [Current Status](#current-status)); the operator installs Homebrew from brew.sh. |
| `ghc` | host `ghc` resolved | Apple: `brew install ghcup` + `ghcup install ghc`. |
| `cudawin` | `nvcc -V` resolves, `vswhere` finds VCTools, `clang` resolves, the NVIDIA driver reports a GPU, and an `nvcc -ccbin <MSVC>` smoke artifact compiles | windows-gpu: unattended `winget install` of the CUDA Toolkit (`Nvidia.CUDA`), MSVC C++ Build Tools/VCTools (`Microsoft.VisualStudio.2022.BuildTools`), and LLVM (`LLVM.LLVM`); the NVIDIA Windows driver is a substrate precondition, not auto-installed. |
| `wsl2` | Ready when `wsl --status` succeeds without reporting disabled virtualization, or fails reporting no installed distributions; otherwise ready when `wsl --list --online` succeeds without reporting disabled virtualization and names Ubuntu-24.04 (a catalogue listing, not a platform observation; see [Current Status](#current-status)) | windows, when not ready: firmware virtualization disabled fails fast; firmware enabled and hypervisor present runs `winget install` of `Microsoft.WSL`, `wsl --install --no-distribution`, and `wsl --set-default-version 2`, then re-probes; hypervisor absent runs only `bcdedit /set hypervisorlaunchtype auto` and exits with a reboot-required diagnostic, leaving the WSL install steps to the next run after the reboot. A step output that asks for a reboot also exits with that diagnostic. A project-owned `deploy-vm` step registers that project's own named Ubuntu-24.04 distro. |
| `incus` | Three probes after a client check: an `incus list` whose failure text is read as absent, permission-denied, or unreachable daemon; VM capability (QEMU, OVMF, and `virtiofsd` on Linux, the `incus` Colima profile on Apple); and `images:ubuntu/24.04` egress. The first failing probe in that order names the status; all passing is ready, and only the ready status mints `IncusProviderCapability` | Apple: `brew install incus`, `brew install colima`, `colima start incus --runtime incus`, then final provider/profile/egress probe. Linux: install `incus` + `acl` and run `incus admin init --minimal` when the client is absent; then, on every run, ensure `/dev/kvm` access, install `qemu-system-x86`, `ovmf`, `virtiofsd`, and `acl`, initialize the daemon when a root `incus list` fails, restart `incus` unconditionally, grant `incus-admin` and immediate socket access, preserve `incusbr0` forwarding through `DOCKER-USER`, then run the same final capability/egress classification. |

## Current Provider Probes And Target Usability

The managed provider contract does not call a provider ready merely because its package is on disk. It requires the
capability the dependent operation consumes and, where subsequent work pulls remote inputs, working
egress. Current Incus code implements that provider observation, while general lifecycle integration
still returns a result-free reconciler action:

- **One group-and-socket workflow.** Putting the invoking non-root user in a daemon's group and granting
  that user immediate access to the daemon's socket is one workflow in `HostBootstrap.Ensure`, taking the
  group, the socket, and the reconciler's label. `docker` and `incus` are applications of it; a host with
  no invoking non-root user is a reported skip rather than a failure. The three-way answer to a
  privileged step — succeeded, ran and returned non-zero, could not be run — is written once beside it.
- **One accelerator listing predicate.** `reportedGpu` answers whether a captured device listing reported
  a device, over the `nvidiaDeviceMarker` token `HostBootstrap.Substrate` names, so the host-driver check,
  the `nvkind` runtime smoke, and the Windows reconciler cannot disagree about what a listing means.
  Outer-host detection shares only the token, not the predicate: it treats the NVIDIA kernel marker files as
  sufficient before any listing, so a host detection classifies as a GPU host can still fail a reconciler's
  listing check.
- **`ensure docker`** checks that the invoking process can reach the Docker daemon. On Linux the install
  path also grants socket access through group membership and an immediate ACL. On Apple a missing
  daemon is refused at this config-free seam, naming the plan-bound Colima adapter as the owner of Apple
  host Docker; no demo or production lifecycle step drives that adapter (see
  [Current Status](#current-status)).
- **The prepared Colima adapter** is deliberately not a `Reconciler` row, because it needs validated
  project, plan, budget, partition, reservation, and profile evidence that a config-free reconciler cannot
  hold. Its module surface (plan and evidence joins, the in-process native Apple toolchain resolver, the bounded runner, the
  storage split) is described in [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md#module-surface);
  its durable stage records, conflict rules, and cleanup ordering are its row in the
  [per-backend clause matrix](../architecture/ownership_invariant.md#per-backend-clause-matrix); and the
  resource wall it applies is in [applied_cordon](applied_cordon.md). The
  [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
  owns it.
- **`ensure incus` on Apple and Linux** converges its substrate-specific provider, then probes daemon
  reachability, VM capability, and `images:ubuntu/24.04` metadata egress. Absence, permission denial, and
  unreachability are three readings of the one daemon listing's failure, not separate probes; they, VM
  capability, and egress remain distinct typed statuses, and only ready enters the opaque capability
  continuation. See [incus](incus.md) and [cluster_lifecycle](cluster_lifecycle.md).

Egress still matters because later steps pull base images and warm-store inputs; forwarding a Docker Hub
credential down the lift supplies authentication but does not prove network reachability. Incus
checks its image-server route, but other provider/dependent routes must retain their own exact
observations. See
[composition_methodology](../architecture/composition_methodology.md) for credential forwarding and
[lifecycle_state_model](../architecture/lifecycle_state_model.md) for the typed observation and authority boundary.

## Reconciler Inventory

| Reconciler step | Applies to | Fail-fast behavior on wrong host |
|-----------------|------------|----------------------------------|
| `ensure-docker` | applicability predicate accepts all substrates | It installs/grants access only on Linux. On Apple, absence refuses and names the prepared per-project Colima adapter as owner; on Windows, absence refuses because Docker belongs to the WSL2/provider path. A reachable pre-existing daemon is accepted. It does not verify egress. |
| `ensure-lima` | `apple-silicon` | Errors on every other substrate: Lima is the macOS VM provider used by the demo pristine Linux VM; Linux uses native Incus and Windows uses WSL2 for the demo VM. |
| `ensure-apple-metal` | `apple-silicon` | Errors off Apple Silicon: verifies a visible Metal device, the macOS SDK through `xcrun`, and a Swift + Metal compile/run probe for the host-native accelerator daemon. It has no meaning in a Linux daemon pod or on Windows. |
| `ensure-cuda` | `linux-gpu` | Errors on every other substrate (`linux-cpu`, `apple-silicon`, `windows-cpu`, `windows-gpu`): it reconciles the Linux NVIDIA container runtime only. |
| `ensure-homebrew` | `apple-silicon` | Errors on every other substrate: Homebrew is the macOS host package manager and an independently installed host minimum; the step verifies its presence and fails fast with its instruction when it is absent. |
| `ensure-ghc` | `apple-silicon` | Errors on every other substrate: reconciles the Apple host GHC toolchain. The host build toolchain itself is ensured pre-binary by the bootstrapper, since every substrate builds host-native. |
| `ensure-cudawin` | `windows-gpu` | Errors on `windows-cpu`, `linux-*`, and `apple-silicon`: verifies the non-installable NVIDIA driver/GPU prerequisite, reconciles CUDA Toolkit + MSVC VCTools + LLVM clang for the headless host build, and compiles a CUDA smoke artifact through `nvcc -ccbin <MSVC>`; it has no meaning off a Windows GPU host. |
| `ensure-wsl2` | `windows-cpu` and `windows-gpu` | Errors off Windows: enables WSL/VMP and reconciles Windows hypervisor launch readiness. A separate project-owned `deploy-vm` step registers that project's own named `Ubuntu-24.04` distro that is the Windows VM frame, peer of Lima/Incus. See [wsl2](wsl2.md). |
| `ensure-incus` | `apple-silicon` and `linux` | Two rows, and no Windows row. It converges the frame-specific provider and requires the final status of its three probes (daemon listing, VM capability, image egress) to be ready. See [incus](incus.md). |

`ensure-incus` has two rows (apple and linux) and no Windows row. `ensure-docker` has a row for every host
frame, which is what makes its diagnostic read `all substrates`; only its Linux row installs, while the
apple and Windows rows delegate through `ProvidedElsewhere`. Every other reconciler has one row.

## Guest Bootstrap Vocabulary

Every command the binary issues in a frame is one of the binary's own typed operations, lifted — except in a
frame that has never run the binary, which cannot issue one, and into which no binary may be copied because
every binary is built host-native. The steps that **establish** the binary in a fresh frame are therefore
their own closed, ordered, typed vocabulary, owned by `HostBootstrap.Ensure.GuestBootstrap` and by nothing
else.

It is a reconciler in shape — probe, plan, act, re-probe — over a frame instead of a host, and it has five
steps because each is separately probeable: the distribution floor, the pinned toolchain, the Python
bootstrapper, the host-native build in the frame, and installing the result where the next lift invokes it.
`guestBootstrapPlan` emits each of the five step constructors exactly once, in a fixed order, so a caller that goes through
`guestBootstrapPlan` or `runGuestBootstrap` chooses the target and never the sequence.

Nothing in it is a shell string. Each step renders to argument vectors: the probe answers with its exit
status alone, so nothing parses output, and the actions are a list precisely because the two shapes that
otherwise reach for an interpreter do not need one — a piped installer is a fetch step followed by a run
step, and a working directory is an argument to `env` rather than a `cd`.

Every path in a step is a **guest** path: it is interpreted by a process of the frame being bootstrapped,
which is Linux on every outer host. `mkGuestBootstrapTarget` is the only constructor of the abstract
`GuestBootstrapTarget` and admits POSIX-absolute paths alone, so through a target the drive-qualified path a
Windows outer host holds cannot reach a Linux guest process — where it would be a relative path, silently
created wherever the guest happened to start.

Both guarantees — the fixed order and the POSIX-absolute paths — hold for the target API only. The module
also exports the `GuestBootstrapStep` constructors with `stepProbe` and `stepActions`, and those
constructors take unchecked `FilePath` arguments, so a caller that builds steps directly and renders or
sequences them itself bypasses both checks. The demo goes through `runGuestBootstrap`.

The Python bootstrapper asserts Homebrew; on Apple it is the channel through which the bootstrapper
installs `ghcup` for the host-native Haskell build toolchain before a project binary exists. It does not
install Homebrew and does not drive the Colima runtime step. The Haskell core owns the exact
plan/provider/topology/budget/fit/partition/reservation Colima adapter and the other runtime reconcilers.
See [python_haskell_boundary](../architecture/python_haskell_boundary.md).
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
than a per-dependency managed operation. The root coordinator drives the admitted graph through authenticated child frames. The demo invokes
config-free reconciler runners from composite provider/build actions. Guest bootstrap uses its closed
pre-binary vocabulary and shared effect/lift interpretation.

The nine context-free reconcilers are centralized as `allReconcilers` (`docker`, `apple-metal`, `cuda`,
`cudawin`, `homebrew`, `ghc`, `lima`, `wsl2`, and `incus`). Project/config/plan-dependent
provider adapters cannot appear in that list: the Colima adapter requires the prepared project wall, and
there is no standalone `ensure-colima`. Project-owned actions can call `runEnsure` directly when they need a
context-free reconciler in a scripted seam. That remains a library call, not a surfaced command.

## Validation

- `EnsureSpec` covers each reconciler's pure applicability decision, wrong-host diagnostic, and
  substrate-branched install plan; the Incus provider-status classifier; the shared invoking-user
  selection; and, through the injectable `installAndVerifyWith` seam, the already-present no-op,
  install-then-re-probe, install refusal, install failure, and failed re-probe paths without a real
  package manager.
- `SubstrateSpec` covers the host-frame collapse the frame tables read.
- `GuestBootstrapSpec` covers the guest bootstrap plan, its probes and actions, and the target's
  POSIX-absolute path refusal.
- `ColimaSpec` covers the prepared Colima adapter.
- These run in `cabal test all` from `core/`, the host static gate's core leg (see
  [§ JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md)). The IO reconcile actions themselves are
  exercised only by live lifecycle runs on each substrate.

The [ensure reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) owns this contract,
the nine reconcilers, and the guest bootstrap vocabulary.

## Current Status

The Apple Silicon, Linux, and Windows reconciler inventory above is implemented and unit-covered. The
Windows VM-provider reconciler `ensure-wsl2` is implemented; current hardware/lifecycle closure belongs
in the development plan. The closed registry contains no `ensure-tart` member.

The following gaps between the code and the contract above are owed by the
[ensure reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md):

- **WSL2 readiness.** `wsl2Ready` falls back to `wsl --list --online`, which observes that the online
  distribution catalogue is reachable rather than that the WSL2 platform can run a VM, so it can report a
  no-op on a host whose WSL2 platform is not usable. Its no-hypervisor branch runs only `bcdedit` and
  exits reboot-required, leaving the WSL install steps to a later run.
- **Linux Incus idempotence.** The Linux row re-runs its QEMU/OVMF/`virtiofsd` package install and
  restarts the `incus` daemon on every run, including on a host that is already ready, so it is not the
  verified no-op the contract requires.
- **Incus capability gate.** `withIncusProviderCapability` takes an `IncusProviderStatus` rather than
  running `probeIncusProviderStatus` itself, and `IncusProviderReady` is exported, so a caller can mint
  `IncusProviderCapability` from a status it constructed without observing the provider.
- **Homebrew diagnostic.** The `ensure-homebrew` refusal says the Python bootstrapper installs Homebrew;
  the bootstrapper only asserts it.
- **Guest bootstrap boundary.** The exported `GuestBootstrapStep` constructors accept unchecked paths, so
  the fixed order and the POSIX-absolute path rule hold only for callers that use the target API.

Direct Colima is a plan-owned adapter rather than a context-free reconciler. Its public prepared-wall
path uses one native protected-entry acquisition, cleanup, and routed-Docker driver over the shared
ownership seam and closed durable-stage vocabulary. External commands run through the installed binary's
bounded parent-death transaction in the isolated Colima/Docker namespace. No production recursive or demo
call site consumes the adapter — the CLI reaches only its backend runner's private command entry — and no
phase schedules such a consumer. Its live coverage is the separate direct-Colima lane of
[Apple Silicon acceptance](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md); the Apple demo
uses Lima. The native ownership driver and resolver are owned by the
[cluster-lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).

The accelerator build-stack reconcilers are implemented. Current static and hardware closure, including
native Linux `nvkind` and accelerator lifecycle validation, is owned by
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).
