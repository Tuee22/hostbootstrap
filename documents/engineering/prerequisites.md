# Prerequisites

**Status**: Authoritative source
**Supersedes**: prior host-prerequisite notes without metadata
**Referenced by**: [../README.md](../README.md), [schema.md](schema.md), [base_image.md](base_image.md)

> **Purpose**: Define the small set of host minimums the thin Python bootstrapper asserts fail-fast
> before any project binary exists, and point everything else at the Haskell `ensure` reconcilers.

## TL;DR

- The Python bootstrapper asserts a **minimal, fail-fast** set of host minimums before the project
  binary can be built. Other binary-owned reconcilers and lifecycle gates also fail fast; this page owns
  only the pre-binary floor.
- Dependencies beyond those minimums and the pre-binary Haskell build toolchain are owned by Haskell
  lifecycle/reconciler actions. When a current probe reports absence and a supported platform install
  plan exists, the
  reconciler installs and re-runs that probe rather than documenting a manual prerequisite. The target
  makes that a total install-and-verify contract; current weak probes, notably Linux Incus client
  presence, remain open. Hardware/firmware capabilities that cannot be safely installed — notably the
  Linux or Windows NVIDIA display driver — remain explicit preconditions. See
  [ensure_reconcilers.md](ensure_reconcilers.md).
- A missing *minimum* aborts with a one-line diagnostic and a non-zero exit; it is never worked around.
  A reconciler also fails fast for a wrong-host misuse or an irreducible hardware/firmware precondition;
  mere absence of a package with a supported install plan on that substrate triggers reconciliation
  instead.
- Bootstrapper freshness is not a host minimum. Normal commands do not check whether the pipx-installed
  wrapper is at the latest commit; self-update is explicit and documented in [self_update.md](self_update.md).

## Why The Split

The Python layer runs *before any project binary exists*, so it can only depend on the host shell
and a handful of system tools. Its job is to assert the host is bootstrappable, ensure the host build
toolchain, build the project binary host-native into `./.build/<executable>`, and invoke it. Handoff
replaces the Python process with `exec` on POSIX and runs a child subprocess on Windows. The split is
between what the wrapper asserts and what the binary owns: the wrapper asserts only the **pre-binary
build floor**, which is identical for `hostbootstrap build`, `hostbootstrap doctor`, and `hostbootstrap
run` on every substrate. Runtime host preconditions (a usable `/dev/kvm`, the `linux-gpu` NVIDIA
container runtime) are the binary's `ensure` responsibility, not the wrapper's. All richer
host-management logic lives in `hostbootstrap-core` as `ensure` reconcilers and runs through the
project binary (or `hostbootstrap-core`'s own bare binary).

## Linux Minimums

The Python bootstrapper asserts, fail-fast:

- **Ubuntu 24.04.** The supported Linux substrate (`linux-cpu` and `linux-gpu`).
- **Passwordless sudo.** Required for the host package and Docker setup the `ensure` reconcilers
  perform.
- **curl.** Required for the pinned, SHA-256-verified GHCup bootstrap download.
Hardware virtualization is **not** a Python minimum. A usable `/dev/kvm` is a runtime precondition the
binary self-heals in `ensure incus` (loading the `kvm` module if the node is absent, granting the invoking
user `rw` via `setfacl` if it is present-but-unwritable, and failing fast only when firmware virtualization
is genuinely disabled) — so `build`, `doctor`, and `run` share one identical Linux floor.

Docker itself is **not** a Python minimum on Linux either; `ensure docker` provisions it, starts the daemon,
grants the invoking user `docker` socket access for future login sessions, applies an immediate socket
ACL when the current process has not observed refreshed groups yet, and verifies that access.
GPU specifics are not Python minimums. On `linux-gpu`, the NVIDIA kernel driver is an irreducible
runtime precondition: `ensure cuda` requires `nvidia-smi -L` to report a GPU and does not install the
driver. The reconciler does install the absent-but-installable portion through NVIDIA's signed Debian
apt source: `nvidia-container-toolkit`, Docker's NVIDIA runtime set as the default, CDI enabled, and
`accept-nvidia-visible-devices-as-volume-mounts=true`. Its satisfied probe is the exact `nvkind`
volume-injection smoke — `docker run --rm -v
/dev/null:/var/run/nvidia-container-devices/all ubuntu:20.04 nvidia-smi -L` — so merely listing an
`nvidia` runtime is insufficient. The direct demo chain runs `ensure docker` and `ensure cuda` before it
builds the CUDA-flavored project image and hands it off with `--gpus=all`.

The Linux GPU install planner and no-op classifier have unit coverage. Historical WSL2 evidence is not a
native-Linux lifecycle gate. Current status and exact dated test evidence belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Apple Silicon Minimums

The Python bootstrapper asserts, fail-fast:

- **Passwordless sudo.**
- **Xcode Command Line Tools.**
- **Homebrew.**

These three are the bedrock the Apple bootstrap path needs before it can ensure anything else.
Homebrew is the channel through which the bootstrapper installs the host GHC/Cabal toolchain
(`ghcup`) needed to build the binary host-native, so Homebrew's own presence must be a hard
precondition rather than something reconciled. (The Docker provider, `ensure colima`, runs later —
the invoked binary owns it, not the pre-binary bootstrapper.)

## Windows Minimums

Windows is the third metal substrate (`windows-cpu` and `windows-gpu`); its Linux workload runs inside a
WSL2 `Ubuntu-24.04` guest, the structural peer of the Lima (Apple Silicon) and Incus (native Linux) VMs.
The Python bootstrapper asserts, fail-fast:

- **winget.** The Homebrew-analog pre-binary package manager, asserted present as a hard precondition
  rather than reconciled (exactly as Homebrew is on Apple). `ensure cudawin` later uses it to install the
  CUDA Toolkit and MSVC build tools; the host GHC/Cabal toolchain (`ghcup`) is bootstrapped separately by
  a direct PowerShell download (`Invoke-WebRequest`), not through winget.
- **PowerShell.** The host shell the pre-binary bootstrapper runs in (it drives the ghcup download).

On `windows-gpu` the host additionally needs the **NVIDIA Windows driver** as an irreducible
precondition for the headless host-build CUDA path (`ensure cudawin`, composition pattern #7).
`ensure cudawin` installs the absent CUDA Toolkit and compiler stack through winget; that installable
tooling is not a Python prerequisite. This is distinct from the in-container `linux-gpu` toolkit
reconciled by `ensure cuda`.

WSL2 is **not** a Python pre-binary minimum. `ensure wsl2` prepares the Windows platform: it installs or
enables WSL2 / Virtual Machine Platform as needed, sets WSL version 2, checks virtualization and
hypervisor readiness, and classifies a reboot-required state. It deliberately uses
`wsl --install --no-distribution`; the project-owned `deploy-VM` step later registers that project's
named `Ubuntu-24.04` distro, applies its VHDX cap, and creates the actual VM frame. The in-distro Linux
frame then applies its own Linux minimums. The host CUDA capability (`ensure cudawin`) also runs later,
owned by the invoked binary, not the pre-binary bootstrapper.
The Windows GHCup download is versioned but the Python path does not verify a checksum or signature before
execution. That provenance gap, and current Windows lifecycle status, are documented in
[Python/Haskell boundary](../architecture/python_haskell_boundary.md) and the development plan.

## Post-Binary Reconciliation And Platform Limits

The following are not additional Python checks. The Haskell side owns their post-binary probe/install or
delegation path. A supported absent package is installed and re-probed; absence on a substrate without
an install plan is refused or delegated to that substrate's provider. The current probe may still be too
weak to establish the capability its label promises:

| Concern | Reconciler | Applies on |
|---|---|---|
| Docker reachability | `ensure docker` | applicability accepts all substrates; installation is Linux-only, Apple delegates to Colima, and Windows delegates to WSL2/provider setup |
| Default Colima runtime profile (currently unsized) | `ensure colima` | Apple silicon |
| Lima pristine demo VM provider | `ensure lima` | Apple silicon |
| Incus host-provider | `ensure incus` | Apple silicon (Colima-backed) and Linux (native daemon) |
| NVIDIA container toolkit + Docker runtime/CDI/volume injection (NVIDIA kernel driver is a precondition) | `ensure cuda` | `linux-gpu` |
| Homebrew presence | `ensure homebrew` | Apple silicon; verification-only because Homebrew is already a pre-binary minimum |
| WSL2 platform and hypervisor readiness (the later `deploy-VM` step creates the distro) | `ensure wsl2` | Windows (`windows-cpu` / `windows-gpu`) |
| Headless host-build CUDA (NVIDIA driver precondition; CUDA Toolkit + MSVC via winget) | `ensure cudawin` | `windows-gpu` |

See [ensure_reconcilers.md](ensure_reconcilers.md) for each reconciler's host-applicability
predicate and reconcile action.

## Bootstrapper Freshness Is Not A Minimum

The pipx-installed Python wrapper may be updated explicitly, but being behind the default branch is not
an irreducible host floor. `doctor`, `build`, `run`, and `base` must not contact GitHub to discover
freshness, must not mutate the pipx installation, and must not fail because a newer commit exists.
See [self_update.md](self_update.md).

## Typed Checks In hostbootstrap-core

The fail-fast minimums above are asserted live by the thin bootstrapper's pure-Python `prereqs.py`;
`HostBootstrap.HostPrereqs` mirrors the substrate-dispatched typed minimums without reasserting Docker,
KVM, or NVIDIA runtime state; those transitions belong to their `ensure` reconcilers.
`checkHostMinimums` runs the
labelled checks in order and stops at the first failure, returning a
one-line `PrereqError`. Each check resolves its external tools through the closed `HostTool` enumeration
to absolute paths (`HostBootstrap.HostTool` / `HostBootstrap.HostConfig`) — no `$PATH`-resolved bare
command names. Substrate detection and host-tool resolution are owned by `hostbootstrap-core`. The
pure-Python `prereqs.py` and `substrate.py` are the thin bootstrapper's live fail-fast surface — the
irreducible host floor the pre-binary work depends on. The consolidated host minimums are mirrored in
`HostBootstrap.HostPrereqs`. See
[hostbootstrap_core_library.md](../architecture/hostbootstrap_core_library.md).

> **WRONG** — treating an ensured tool as a manual host prerequisite
>
> ```sh
> brew install colima
> ```
>
> Manually installing or starting the Docker provider bypasses the project lifecycle's dependency ordering
> and can leave its observed state different from the state `project up` expects.
>
> **RIGHT**
>
> Let the project binary's lifecycle invoke the Colima reconciler. The current reconciler executes
> `brew install colima` followed by an unsized `colima start`, and its no-op probe is `colima status` on
> the default profile.
> A budget-sized, per-project Colima profile is a target; the existing sizing argument builder is not yet
> wired into this reconciler.

## Current Status

The pre-binary minimum and binary-owned reconciliation split above describes the current boundary.
Remaining gaps—such as weak provider probes and the unsized default Colima profile—have exact owners and
closure criteria in the development plan. The Linux `curl` floor and GHCup download integrity are
closed. This
page defines what belongs on each side of the boundary; it does not independently declare those phases
closed.

## See also

- [ensure_reconcilers.md](ensure_reconcilers.md) — the reconcilers that cover everything beyond the
  minimums
- [schema.md](schema.md) — the project-local config the binary reads after it is built
- [base_image.md](base_image.md) — the image the project container is built from
