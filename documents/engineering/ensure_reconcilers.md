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
  missing image-server egress, and ready. `withIncusProviderCapability` takes `HostConfig` and runs the
  configured probe before minting the opaque `IncusProviderCapability`. The pure status classifier and
  its descriptive eliminator carry no minting authority. Other reconcilers still vary in probe strength,
  and prepared managed operations provide the separate exact lifecycle authority boundary.
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
  absent on Apple, `ensure wsl2` refuses unavailable virtualization or a reboot-required state, and
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
add a final capability observation after remediation. Linux Incus observes VM capability and the root
daemon before planning package installation, initialization, or restart; its convergence plan is empty
when both observations succeed. Shared permission and forwarding checks remain separate from that plan. A
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
`Left`), `ensure wsl2` refuses unavailable virtualization or a reboot-required state, and
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
own search path. Docker's group check reads command output and native socket metadata rather than
executing a shell. CUDA repository setup uses separate fetch and publication argv with Haskell
validation between them. Linux Incus combines
individual capability, module-loading, and forwarding argv in Haskell; its privileged daemon probe and
initialization retain the resolved absolute Incus executable.
WSL2 machine observations use native bindings. The Apple Metal and Windows CUDA
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
3. **run each step in order** and interpret its result through the pure `classifyStepOutcome`;
4. **refresh the resolved host tools** after each continuing step, including an already-installed
   result, before running the next step;
5. **re-run the same probe** and fail fast with a one-line diagnostic if it is still unsatisfied.

The classifier has four descriptive results:

| `StepOutcome` | Driver interpretation |
|---------------|-----------------------|
| `StepContinue` | Refresh the host configuration and continue. |
| `StepAlreadyInstalled` | Refresh and continue, then run the final probe; the installer message alone does not verify the dependency. |
| `StepRebootRequired` | Stop with the WSL2 reboot-required diagnostic. |
| `StepFailed reason` | Stop with the reconciler's diagnostic prefix and the failure reason. |

A non-zero `winget install` reporting `Found an existing package already installed` or `No available
upgrade found` produces `StepAlreadyInstalled`. Other non-zero exits fail unless the WSL-specific
reboot rules apply. A `Wsl` result that mentions a reboot or restart, whether successful or failed,
produces `StepRebootRequired`; so does exit `-1` from a `Wsl` step containing `--install`. Reboot text
from another tool does not select that path. A runner refusal produces `StepFailed` with its reason.

`HostBootstrap.Ensure` owns `normalizeWslText`, which removes NUL padding from decoded UTF-16 output
and lowercases the text before those WSL checks. `Ensure.Wsl2` reexports the same helper for its
readiness classifiers. `StepOutcome` describes one local install-step result; it carries no retained,
typed lifecycle `Reconcile` evidence.

This is install-and-reprobe mechanically. It is install-and-**verify** semantically only to the extent
that the probe proves the desired state. Docker's daemon probe is a capability check. Incus goes further:
after client convergence its capability gate performs the current configured provider observation and
admits only its ready result. The gate consumes `incusProviderStatusResult`, the same descriptive
eliminator available to status readers, before its sole opaque capability mint. The six non-ready status
constructors are public; the ready constructor is hidden. A caller can still obtain a descriptive ready
result from the pure classifier, while capability admission runs its own probe. It observes the tool paths
resolved in the supplied `HostConfig` at that call. That capability observation remains distinct from the
scoped managed settlement produced by the prepared operation algebra.

Tools are re-resolved after each continuing step, so a freshly installed tool (for example `ghcup` just laid
down by `brew`) is discoverable by the next step. For `Ghc` and `Ghcup` on POSIX hosts, discovery tries
`PATH` first, then `$GHCUP_INSTALL_BASE_PREFIX/.ghcup/bin` when the prefix is configured, or
`$HOME/.ghcup/bin` otherwise. Homebrew formula steps are written as plain
`brew install <formula>` commands; Homebrew's installed-formula no-op behavior is the idempotent
path. The install plan is a **pure** function of the substrate — Homebrew formulae on
`apple-silicon`; `apt-get`/`ghcup`/the NVIDIA container toolkit on Linux — so it is unit-tested
without invoking the package manager (`winget` packages back the Windows install plans); the IO driver
is exercised during real bootstrap runs.

| Reconciler | Current probe | Install plan (per substrate) |
|------------|------------------|------------------------------|
| `docker` | `docker info` reachable and `docker buildx version` succeeds; on Linux the follow-up also verifies observed group-based socket permissions and establishes invoking-user socket access | Linux only: `apt-get update`, then `apt-get install -y docker.io docker-buildx acl`, enable the daemon, and add the invoking user to `docker`. Read `id -nG <user>` through `Sudo` and the fixed socket's owning group and group-write bit; require exact membership in that group before the current-session access path. Retain a successful direct Docker probe, or install ACL support and apply a per-user ACL to `/var/run/docker.sock` when needed. On Apple an absent daemon is refused, naming the prepared per-project Colima adapter as its owner (an adapter no demo or production lifecycle step drives); on Windows it is delegated to the WSL2/provider path. |
| `apple-metal` | `system_profiler` reports a Metal device, `xcrun --sdk macosx --show-sdk-path` returns an SDK path, and a Swift + Metal smoke program compiles and runs | Apple: none — Swift, `xcrun`, the macOS SDK, and Metal come with the Xcode Command Line Tools; an unsatisfied probe fails fast with the `xcode-select --install` instruction. |
| `lima` | `limactl` resolved | Apple: `brew install lima`. |
| `cuda` | `nvidia-smi -L` reports a GPU and Docker's official nvkind volume-mount smoke (`/dev/null:/var/run/nvidia-container-devices/all`) sees that GPU | linux-gpu: when the smoke is not satisfied, establish repository tools, fetch and validate the NVIDIA repository inputs, then publish the keyring and signed-by list. The runtime tail refreshes apt, installs `nvidia-container-toolkit`, configures the NVIDIA runtime as Docker's default with CDI, enables `accept-nvidia-visible-devices-as-volume-mounts`, and restarts Docker before the final smoke. The kernel driver is a substrate precondition, not auto-installed. An initially satisfied probe skips all installation and repository work. |
| `homebrew` | `brew` resolved | Apple: none — the Python bootstrapper asserts Homebrew as a host minimum; an absent `brew` fails fast with the instruction to install it from https://brew.sh and retry. |
| `ghc` | host `ghc` resolved through `PATH` or the POSIX ghcup fallback | Apple: `brew install ghcup` + `ghcup install ghc --set recommended`, selecting ghcup's recommended GHC as default. The guest compiler pin remains in `PinnedToolchain`; the pre-binary host pin belongs to the bootstrapper. |
| `cudawin` | `nvcc -V` resolves, `vswhere` finds VCTools, `clang` resolves, the NVIDIA driver reports a GPU, and an `nvcc -ccbin <MSVC>` smoke artifact compiles | windows-gpu: unattended `winget install` of the CUDA Toolkit (`Nvidia.CUDA`), MSVC C++ Build Tools/VCTools (`Microsoft.VisualStudio.2022.BuildTools`), and LLVM (`LLVM.LLVM`); the NVIDIA Windows driver is a substrate precondition, not auto-installed. |
| `wsl2` | One `wsl --status` observation: virtualization-disabled text takes precedence over every exit code and other marker; otherwise exit 0 or a no-installed-distributions report means ready, and other failures or an unrunnable tool mean absent. `wsl --list --online` is not queried. | Ready sets the default version to 2. Otherwise a present hypervisor selects installation without consulting the firmware flag. With no hypervisor and available virtualization, an absent platform is installed; an unavailable platform enables hypervisor launch and asks for a reboot. Unavailable virtualization is refused. Installation runs `winget install` of `Microsoft.WSL`, `wsl --install --no-distribution`, and `wsl --set-default-version 2`, then re-probes. A WSL step output asking for a reboot also stops with that diagnostic. The project-owned `deploy-vm` step registers its named Ubuntu-24.04 distro. |
| `incus` | The capability gate takes `HostConfig` and runs three probes after a client check: an `incus list` whose failure text is read as absent, permission-denied, or unreachable daemon; VM capability (QEMU, architecture-specific firmware, and executable `virtiofsd` on Linux, the `incus` Colima profile on Apple); and `images:ubuntu/24.04` egress. The first failing probe in that order names the status; only the gate's observed ready result mints `IncusProviderCapability`. The pure classifier and status eliminator remain descriptive. | Apple: `brew install incus`, `brew install colima`, `colima start incus --runtime incus`, then final provider/profile/egress probe. Linux: install `incus` + `acl` when the client is absent and refresh tool resolution. Observe VM capability and the root daemon: install architecture-specific QEMU/firmware plus `virtiofsd` and `acl` only on a capability gap; initialize through the retained absolute Incus executable only on a daemon gap; restart once when either ran. Then refresh tool resolution, ensure `/dev/kvm` access, grant `incus-admin` and immediate socket access, preserve `incusbr0` forwarding through an existing `DOCKER-USER` chain, and run the final capability/egress classification. |

After WSL's installation driver succeeds, including its already-ready fast path, the reconciler refreshes
tool resolution and runs the same default-version-2 action as the direct ready path. A readiness result
that changes between probes therefore cannot skip default-version convergence.

CUDA repository preparation is an explicit runtime stage before the static `installSteps` tail.
`repositoryToolSteps` supplies only the real package commands needed for missing repository tools.
The reconciler observes typed `Curl` resolution and a successful `gpg --version`, installing tools and
refreshing `HostConfig` when needed. `setupRepositoryWith` then owns a unique scratch directory for
both `curl -fsSL -o` downloads. It strictly reads both files and validates the repository list before
running either privileged destination command. `signedByListText` adds the fixed keyring to supported
active NVIDIA HTTPS entries, preserves comments, blank lines and final-newline behavior, and refuses
empty or unsupported repository bodies.

Only after those checks does the reconciler run `Sudo` for key dearmoring and list installation, then
consume the actual runtime tail and re-run the nvkind smoke. Failed fetches or refused input leave
both destination files untouched. Publication is ordered; it does not promise atomic replacement of
both files or rollback after a publication command fails. Ordinary IO errors refuse, while asynchronous
cancellation propagates after scratch cleanup.

For Linux Incus, `LinuxIncusObservation` retains the root probe's absolute Incus executable alongside VM
and daemon observations. `linuxIncusConvergence` chooses among an empty plan, VM packages plus restart,
daemon initialization plus restart, and both changes plus one restart. Amd64 uses `qemu-system-x86` and
`ovmf`; Arm64 uses `qemu-system-arm` and `qemu-efi-aarch64`. The capability probe combines QEMU,
firmware alternatives, and virtiofsd alternatives in Haskell. Its typed `Virtiofsd` PATH fallback still
requires a successful executable check. KVM module loading rechecks `/dev/kvm` after each ordered
`kvm_intel`, `kvm_amd`, and `kvm` attempt. Forwarding skips a missing `DOCKER-USER` chain and checks
each rule before inserting it. These decisions do not establish that privileged execution has passed
on a live host; that confirmation belongs to the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

## Current Provider Probes And Target Usability

The managed provider contract does not call a provider ready merely because its package is on disk. It requires the
capability the dependent operation consumes and, where subsequent work pulls remote inputs, working
egress. Current Incus code implements that provider observation, while general lifecycle integration
still returns a result-free reconciler action:

- **One group-and-socket workflow.** Putting the invoking non-root user in a daemon's group and granting
  that user immediate access to the daemon's socket is one workflow in `HostBootstrap.Ensure`, taking the
  group, the socket, and the reconciler's label. `docker` and `incus` are applications of it; a host with
  no invoking non-root user is a reported skip rather than a failure. `withInvokingGroupMember` hands
  its grant callback one checked privileged-step function and the selected user; `grantSocketAccess`
  renders its `setfacl` request through that function. The three-way answer — succeeded, ran and returned
  non-zero, could not be run — is formatted once from the reconciler's label and step description.
  A non-zero exit names the step and code; a runner refusal retains the runner's text after the label.
  `requireSudoStep` uses the same checked formatter.

  `withInvokingGroupMemberWith` takes the environment, an effective-user lookup, and a `Sudo` runner.
  It uses the same workflow and grant renderer, so a recording runner observes the real `usermod -aG`
  and `setfacl -m` argument vectors without running privileged commands. Selection prefers non-empty,
  non-root `SUDO_USER`, then `LOGNAME`, then `USER`, before consulting the effective user. POSIX uid 0,
  an effective uid with no passwd entry, and Windows without an environment-selected user yield the skip
  path. A synchronous passwd lookup `IOError` also yields no user; asynchronous cancellation propagates.
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
  [Current Status](#current-status)). Docker's `verifyDockerGroupWith` checks the future login's
  group-based permissions with a result-producing `Sudo` runner for `id -nG <user>` and a supplied
  socket observation. Production supplies the native Haskell reader of `/var/run/docker.sock`'s owning
  group name and group-write bit. Membership must match a complete group-name token and the actual
  socket group must be writable. Command or metadata refusal stops before the current-session access
  continuation. This observes permissions; it does not execute a future login or prove that login can
  reach the daemon. The native socket observation explicitly refuses as unsupported on Windows; the
  Linux-only group workflow does not change Windows Docker delegation.

  Docker retains its current-session direct Docker probe and, when needed, ACL-tool installation and
  socket grant after successful permission verification. Incus supplies its own group and socket to
  the shared grant.
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

The five steps establish the distribution floor, pinned toolchain, Python bootstrapper, host-native
project build, and installed project binary, in that order. `guestBootstrapPlan` enumerates the closed
`GuestStepKind` axis and maps it through exhaustive `stepFor`; `stepKind` identifies each resulting step.
A caller using the plan selects the target and never the sequence.

Ordinary steps probe first, act on absence, and re-probe. The bootstrapper step always runs
`pipx install --force <source>` and then verifies its executable, without an initial skip probe. This
refreshes the staged source even on an otherwise satisfied frame and reports `GuestStepInstalled`.
The driver stops at the first runner failure, failed action, or unsettled verification, naming the step.

Each probe is an argument vector. The floor uses `dpkg-query`'s `${db:Status-Abbrev}\n` format and
`floorPackagesSatisfied`: success requires a non-empty floor, exit 0, exactly one non-empty status line
per requested package, and every line beginning `ii`. Removed-with-config (`rc`), unpacked (`iU`), empty, truncated,
or failed results are absent. Other probes use their exit status; the toolchain probe requires ghcup,
the exact versioned GHC executable, and Cabal together.

Nothing in the vocabulary is a shell string. Actions are a list precisely because the two shapes that
otherwise reach for an interpreter do not need one — a piped installer is a fetch step followed by a run
step, and a working directory is an argument to `env` rather than a `cd`.

Every path in a step is a **guest** path: it is interpreted by a process of the frame being bootstrapped,
which is Linux on every outer host. `mkGuestPath` admits an opaque `GuestPath` only for a POSIX-absolute
path, refusing a drive-qualified outer-host path that a Linux guest would read as relative.
`guestPathValue` returns the original spelling. Each admitted path is labeled with its coordinate role
before `mkGuestBootstrapTarget` receives it. The target and matching step payloads retain all six roles
until rendering. The target checks the empty toolchain pin first, then the toolchain home's final
`.ghcup` component without a trailing separator. The installer receives that home's parent as
`GHCUP_INSTALL_BASE_PREFIX`.

The first coordinate has its own opaque `GuestSourceRoot`. Its total builder `mkGuestSourceRoot` wraps
an admitted `GuestPath`, and `guestSourceRootPath` reads that proof. The factory argument, target reader
and bootstrapper-source step payload retain the role until its path is rendered into the source label
and `pipx install --force` argv. The demo admits `vmRepoRoot` and labels it with that role at its existing
target call.

The build's working directory has its own opaque `GuestProjectDir`. The total `mkGuestProjectDir` builder
wraps an admitted `GuestPath`, and `guestProjectDirPath` reads it. The second factory argument, target
reader and build payload retain that role until the build label and `env -C` argv render its path.
The demo admits and labels `vmDemoRoot` at the same target call. The built-binary output remains an
independent coordinate with its existing spelling.

The toolchain home has its own opaque `GuestToolchainHome`. Its total `mkGuestToolchainHome` builder
labels an admitted `GuestPath`, and `guestToolchainHomePath` returns that proof with its original spelling.
The third factory argument, target reader and toolchain/build payloads retain the role. The target still
checks the `.ghcup` component after the empty pin; the role builder supplies
the coordinate label, while that target predicate checks the home shape. The demo admits `/root/.ghcup`
and labels it at the actual target call. Existing POSIX derivations render the executable probes,
installer filename and parent install-base prefix, and the build PATH. Step labels remain unchanged.

The bootstrapper executable has its own opaque `GuestBootstrapperExe`. The total
`mkGuestBootstrapperExe` builder wraps any admitted `GuestPath`, and `guestBootstrapperExePath` reads that
proof. The fourth factory argument, target reader and bootstrapper/build payloads retain the role.
The demo admits `/root/.local/bin/hostbootstrap` and labels it at the actual target call. Rendering uses
the original path for the executable `test -x` probe and build invocation, and its POSIX parent in the
build PATH. The role identifies the coordinate; executable readiness remains a runtime observation.
The existing `pipx install --force` source action and all step labels remain unchanged.

The build output has its own opaque `GuestBuiltBinary`. Its total `mkGuestBuiltBinary` builder wraps
any admitted `GuestPath`, and `guestBuiltBinaryPath` returns that proof. The fifth factory argument,
target reader, build-output payload and install-source payload retain the role. The demo admits its
existing `vmDemoRoot ++ "/.build/hostbootstrap-demo"` spelling and labels it at the target call.
Rendering uses that path in the build's `test -x` probe, comparison source and install source; build argv
and all labels remain unchanged. The role records the path's purpose, while existence and readiness
remain runtime observations.

The installed destination has its own opaque `GuestInstalledBinary`. Its total `mkGuestInstalledBinary`
builder labels an admitted `GuestPath`, and `guestInstalledBinaryPath` reads that proof. The sixth factory
argument, target reader and install-destination payload retain the role. The demo admits and labels
`/usr/local/bin/hostbootstrap-demo` at its existing target call. Rendering uses that spelling in the
installation label, comparison destination and install destination. This is a path-purpose role;
installation and readiness remain runtime observations.

All seven target record labels are private. Ordinary readers return the source-root, project-directory,
toolchain-home, bootstrapper-executable, built-binary and installed-binary roles plus the pinned toolchain,
so inspection does not expose record update.
`GuestBootstrapStep` is abstract too: its public steps come from `guestBootstrapPlan` over an admitted
target, with `stepKind`, `stepLabel`, `stepProbe`, and `stepActions` for observation. The provided
`runGuestBootstrap` driver uses the plan's fixed order.
Original path spelling, literal argv, journals, and target/step `Show` presentation remain compatible.

All six factory coordinates and matching step payloads now require their distinct purpose roles. The
demo admits and labels each path at its actual call; the role views preserve the original path values.

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

The direct Linux GPU metal step runs `ensure cuda` before entering the project container. When
remediation is needed, it configures the default-runtime/CDI/volume-mount settings consumed by nvkind.
The official volume-mount smoke checks the default runtime and effective volume-mount injection;
CDI is configured by the install tail but is not verified by that smoke. Whether a particular native or
virtualized host has passed the hardware gate is plan-owned evidence, not part of this stable contract.

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
  substrate-branched install plan, including the recommended-default GHC argv, ghcup fallback
  candidates, and Docker/Homebrew delegation text; the Incus provider-status classifier, descriptive
  refusals, and configured capability admission; shared invoking-user
  selection and effective-user fallback; the group/socket workflow's exact privileged argv, skip,
  non-zero, and runner-refusal paths; the four-way install-step classifier, including NUL-padded WSL reboot text and reboot
  text from another tool; and, through the injectable `installAndVerifyWith` seam, the already-present
  no-op, install-then-re-probe, second-run no-op, install refusal, install failure, failed re-probe,
  and winget already-installed refresh-and-re-probe paths without a real package manager.
- `SubstrateSpec` covers the host-frame collapse the frame tables read.
- Docker permission cases exercise the production verification workflow with recorded `id -nG` argv
  and supplied socket observations: whole-token membership, the actual owning group, the group-write
  bit, command/metadata refusals, and refusal before the ACL continuation. They also pin apt update
  before Linux package installation. These static controls do not mutate host users, groups, or sockets,
  execute a future login, or establish live daemon connectivity.
- CUDA repository cases cover the real tool-bootstrap commands and runtime tail, supported list bytes
  and refusals, exact scratch download/publication argv, cleanup, and refusal before publication when
  either download or validation fails. A recording runner exercises the production scratch workflow;
  these cases do not establish a live repository, signing trust, GPU availability, or CDI operation.
- `GuestBootstrapSpec` covers the step-kind order, exact probe/action argv, package-state classification,
  unconditional source refresh, per-step driver journals and refusals, common POSIX path admission and
  the target's pin/`.ghcup` checks. Path admission precedes the six role labels; ordinary-reader and presentation
  controls retain original spelling and pin-before-home diagnostics without importing step constructors.
  Alternate-path cases check each role's exact rendering positions. Public-only record-update and
  step-construction fixtures, plus the exact export inventory, guard the sealed boundary. The
  [binary-role transposition fixture](../../core/hostbootstrap-core/test/compile-fail/TransposeGuestBinaryRoles.hs)
  builds admitted values for every role and rejects both swapped built/installed argument positions
  for their role mismatches. These static controls do not establish installation or readiness in a live guest.
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
