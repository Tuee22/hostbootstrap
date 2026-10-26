# Prerequisites

**Status**: Authoritative source
**Supersedes**: prior host-prerequisite notes without metadata
**Referenced by**: [../README.md](../README.md), [schema.md](schema.md), [ensure_reconcilers.md](ensure_reconcilers.md), [gitignore_guardrails.md](gitignore_guardrails.md), [python_haskell_boundary.md](../architecture/python_haskell_boundary.md), [hostbootstrap_core_library.md](../architecture/hostbootstrap_core_library.md)

> **Purpose**: Define the small set of host minimums the thin Python bootstrapper asserts fail-fast
> before any project binary exists, and point everything else at the Haskell `ensure` reconcilers.

## TL;DR

- The Python bootstrapper asserts a **minimal, fail-fast** set of host minimums before the project
  binary can be built. Other binary-owned reconcilers and lifecycle gates also fail fast; this page owns
  only the pre-binary floor.
- Dependencies beyond those minimums and the pre-binary Haskell build toolchain are owned by Haskell
  lifecycle/reconciler actions. When a current probe reports absence and a supported platform install
  plan exists, the
  reconciler installs and re-runs that probe rather than documenting a manual prerequisite. A re-probe
  verifies only as much as its probe observes: some probes establish usability and some only presence,
  and the per-reconciler strengths and the open gaps (with their owning phase) are in
  [Current Provider Probes And Target Usability](ensure_reconcilers.md#current-provider-probes-and-target-usability)
  and [Current Status](ensure_reconcilers.md#current-status). Hardware/firmware capabilities that cannot
  be safely installed — notably the
  Linux or Windows NVIDIA display driver — remain explicit preconditions. See
  [ensure_reconcilers.md](ensure_reconcilers.md).
- A missing *minimum* aborts with a one-line diagnostic and a non-zero exit; it is never worked around.
  A reconciler also fails fast for a wrong-host misuse or an irreducible hardware/firmware precondition;
  mere absence of a package with a supported install plan on that substrate triggers reconciliation
  instead.
- Reconcilers are named here by their `ensure-<name>` chain-step label (`reconcilerName` prefixed by
  `ensure-`). They are library values a project's lifecycle actions run, not CLI commands; there is no
  `hostbootstrap ensure` verb.
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
binary self-heals in `ensure-incus` (loading the `kvm` module if the node is absent, granting the invoking
user `rw` via `setfacl` if it is present-but-unwritable, and failing fast only when firmware virtualization
is genuinely disabled) — so `build`, `doctor`, and `run` share one identical Linux floor.

Docker itself is **not** a Python minimum on Linux either; `ensure-docker` provisions it, starts the daemon,
grants the invoking user `docker` socket access for future login sessions, applies an immediate socket
ACL when the current process has not observed refreshed groups yet, and verifies that access.
GPU specifics are not Python minimums. On `linux-gpu`, the NVIDIA kernel driver is an irreducible
runtime precondition: `ensure-cuda` requires `nvidia-smi -L` to report a GPU and does not install the
driver. The reconciler does install the absent-but-installable portion through NVIDIA's signed Debian
apt source: `nvidia-container-toolkit`, Docker's NVIDIA runtime set as the default, CDI enabled, and
`accept-nvidia-visible-devices-as-volume-mounts=true`. Its satisfied probe is the exact `nvkind`
volume-injection smoke — `docker run --rm -v
/dev/null:/var/run/nvidia-container-devices/all ubuntu:20.04 nvidia-smi -L` — so merely listing an
`nvidia` runtime is insufficient. The direct demo chain runs `ensure-docker` and `ensure-cuda` before it
builds the CUDA-flavored project image and hands it off with `--gpus=all`.

The Linux GPU install planner and no-op classifier have unit coverage. Historical WSL2 evidence is not a
native-Linux lifecycle gate. Current status and exact dated test evidence belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Apple Silicon Minimums

The Python bootstrapper asserts, fail-fast:

- **macOS on Apple Silicon (arm64).**
- **Xcode Command Line Tools.**
- **Passwordless sudo.**
- **Homebrew.**

These four, checked in that order, are the bedrock the Apple bootstrap path needs before it can ensure anything else.
Homebrew is the channel through which the bootstrapper installs the host GHC/Cabal toolchain
(`ghcup`) needed to build the binary host-native, so Homebrew's own presence must be a hard
precondition rather than something reconciled. The bootstrapper asserts Homebrew; it never installs it.
The invoked binary, not the pre-binary bootstrapper, owns the prepared per-project Colima Docker-provider
adapter.

## Windows Minimums

Windows is an outer host realization (`windows-cpu` and `windows-gpu`); its universal `linux-cpu` workload runs inside a
WSL2 `Ubuntu-24.04` guest, the structural peer of the Lima (Apple Silicon) and Incus (native Linux) VMs.
The Python bootstrapper asserts, fail-fast:

- **winget.** The Homebrew-analog pre-binary package manager, asserted present as a hard precondition
  rather than reconciled (exactly as Homebrew is on Apple). `ensure-cudawin` later uses it to install the
  CUDA Toolkit and MSVC build tools; the host GHC/Cabal toolchain (`ghcup`) is bootstrapped separately by
  a direct PowerShell download (`Invoke-WebRequest`), not through winget.
- **Windows PowerShell** (`powershell` on `PATH`). The shell the pre-binary bootstrapper drives the
  GHCup download through. PowerShell 7's `pwsh` alone does not satisfy the check.

**Long-path support is reported, not asserted.** `doctor` adds an advisory `long paths:` line on
Windows covering Git's `core.longpaths` and the machine-wide `LongPathsEnabled` policy, and it never
raises. This is deliberate on two grounds. First, the concern is *cleanup*, not the pre-binary build
floor this page owns: the repo-local Cabal store doubles past the 260-char `MAX_PATH` (see
[gitignore_guardrails.md](gitignore_guardrails.md)), which GHC handles fine while `git clean -fxd`
does not — so the host still builds. Second, `hostbootstrap` is a pipx-distributed CLI invoked against
arbitrary project roots, which need not be Git repositories at all; a missing Git setting must never
abort `doctor` on a host where it is irrelevant. The fix, when the advisory does fire, is
`git config --global core.longpaths true` — sufficient on its own for `git clean`, with
`LongPathsEnabled=1` covering non-Git tools.

On `windows-gpu` the host additionally needs the **NVIDIA Windows driver** as an irreducible
precondition for the headless host-build CUDA path (`ensure-cudawin`;
[composition pattern 7, headless host build](composition_patterns.md#frame-topologies)).
`ensure-cudawin` installs the absent CUDA Toolkit and compiler stack through winget; that installable
tooling is not a Python prerequisite. This is distinct from the in-container `linux-gpu` toolkit
reconciled by `ensure-cuda`.

WSL2 is **not** a Python pre-binary minimum. `ensure-wsl2` prepares the Windows platform: it installs or
enables WSL2 / Virtual Machine Platform as needed, sets WSL version 2, checks virtualization and
hypervisor readiness, and classifies a reboot-required state. It deliberately uses
`wsl --install --no-distribution`; the project-owned `deploy-vm` step later registers that project's
named `Ubuntu-24.04` distro, applies its VHDX cap, and creates the actual VM frame ("frame" on this page
is the default topology sense of the [glossary](../README.md#glossary)). The in-distro Linux frame then
applies its own Linux minimums. The host CUDA capability (`ensure-cudawin`) also runs later,
owned by the invoked binary, not the pre-binary bootstrapper.
On Windows, PowerShell `Invoke-WebRequest` downloads the pinned GHCup executable and the bootstrapper
verifies its SHA-256 before installing it, exactly as it does for the Linux `curl` download; see
[Download provenance](../architecture/python_haskell_boundary.md#download-provenance).

## Post-Binary Reconciliation And Platform Limits

The following are not additional Python checks. The Haskell side owns their post-binary probe/install or
delegation path. A supported absent package is installed and re-probed; absence on a substrate without
an install plan is refused or delegated to that substrate's provider. A satisfied probe establishes only
what that probe observes; the per-reconciler probe strengths are in
[ensure_reconcilers.md](ensure_reconcilers.md#install-and-verify). This table lists every member of
`allReconcilers` plus the prepared Colima adapter:

| Concern | Reconciler | Applies on |
|---|---|---|
| Docker reachability | `ensure-docker` | applicability accepts all substrates; installation is Linux-only, while Apple refuses an absent daemon, naming the prepared per-project Colima adapter as owner, and Windows delegates to WSL2/provider setup |
| Exact per-project Colima Docker wall | prepared `HostBootstrap.Ensure.Colima` adapter (not a config-free reconciler; no demo or production lifecycle step drives it) | Apple silicon |
| Lima pristine demo VM provider | `ensure-lima` | Apple silicon |
| Incus host-provider | `ensure-incus` | Apple silicon (Colima-backed) and Linux (native daemon) |
| NVIDIA container toolkit + Docker runtime/CDI/volume injection (NVIDIA kernel driver is a precondition) | `ensure-cuda` | `linux-gpu` |
| Homebrew presence | `ensure-homebrew` | Apple silicon; verification-only because Homebrew is already a pre-binary minimum |
| Apple host GHC toolchain (`brew install ghcup`, then `ghcup install ghc`) | `ensure-ghc` | Apple silicon |
| Swift + Metal host-build tooling (verification-only; Xcode Command Line Tools supply it) | `ensure-apple-metal` | Apple silicon |
| WSL2 platform and hypervisor readiness (the later `deploy-vm` step creates the distro) | `ensure-wsl2` | Windows (`windows-cpu` / `windows-gpu`) |
| Headless host-build CUDA (NVIDIA driver precondition; CUDA Toolkit + MSVC via winget) | `ensure-cudawin` | `windows-gpu` |

See [ensure_reconcilers.md](ensure_reconcilers.md) for each reconciler's host-applicability
predicate and reconcile action.

## Bootstrapper Freshness Is Not A Minimum

The pipx-installed Python wrapper may be updated explicitly, but being behind the default branch is not
an irreducible host floor. `doctor`, `build`, `run`, and `base` must not contact GitHub to check whether
the hostbootstrap wrapper itself is current, must not mutate the pipx installation, and must not fail
because a newer commit exists. This is about the wrapper only: `base` does query the GitHub releases API
to resolve the current upstream tool versions it builds into the base image, so it needs network access.
See [self_update.md](self_update.md).

## Typed Checks In hostbootstrap-core

The pre-binary floor has one implementation: the thin bootstrapper's pure-Python `prereqs.py`, which
asserts the minimums above live. The binary carries no second copy of that floor. After the binary exists,
every prerequisite with an install plan is an `ensure` reconciler, so Docker, KVM, and NVIDIA runtime state
belong to their reconcilers. A bare binary with no bootstrapper in front of it asserts none of the
pre-binary minimums.

`HostBootstrap.HostPrereqs` is dead code: its exported `checkHostMinimums` is a partial, uncalled copy of
the floor (it omits Linux `curl` and checks nothing on Windows) that
[the host tools and substrate detection phase](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md)
deletes, leaving `prereqs.py` the one host-floor implementation; see [Current Status](#current-status). Host-tool resolution is owned by `hostbootstrap-core`: binary-side
checks resolve their external tools through the closed `HostTool` enumeration to absolute paths
(`HostBootstrap.HostTool` / `HostBootstrap.HostConfig`), not `$PATH`-resolved bare command names. Substrate detection is owned by
the bootstrapper, which runs before the binary exists and states what it found through the documented
invocation-context seam; the binary receives that statement and classifies the host itself only when it
was invoked with no bootstrapper in front of it (see
[the Python/Haskell boundary](../architecture/python_haskell_boundary.md)). The pure-Python
`prereqs.py` and `substrate.py` are the thin bootstrapper's live fail-fast surface — the
irreducible host floor the pre-binary work depends on. See
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
> Let the project binary's lifecycle supply its validated context and admitted provider wall to the
> prepared Colima adapter. The adapter installs Colima through Homebrew when absent, observes the named
> project profile, refuses incompatible same-name state, starts only with exact CPU/memory/disk and
> `--activate=false`, and routes Docker through `colima-<project>`. It never treats the mutable `default`
> profile as project authority.

## Current Status

The pre-binary minimum and binary-owned reconciliation split above describes the current boundary.
Probe strengths and platform install coverage vary as described in
[ensure reconcilers](ensure_reconcilers.md). The Apple demo uses Lima, while Apple acceptance exercises
the prepared direct-Colima adapter in a separate native lane. The Linux `curl` floor is asserted, and the
GHCup download is SHA-256-verified on Linux and Windows. This page defines what belongs on each side of the boundary; current acceptance
evidence belongs in the development plan.

`HostBootstrap.HostPrereqs` and its uncalled `checkHostMinimums` remain in the package as a partial
duplicate of the `prereqs.py` floor. Deleting them, with an absence guard that keeps them out, is owed by
[the host tools and substrate detection phase](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md).

## See also

- [ensure_reconcilers.md](ensure_reconcilers.md) — the reconcilers that cover everything beyond the
  minimums
- [schema.md](schema.md) — the project-local config the binary reads after it is built
- [base_image.md](base_image.md) — the image the project container is built from
