---
name: engineering-prerequisites
description: Host prerequisites validated and (where safe) installed by hostbootstrap doctor.
type: reference
---

# Prerequisites

`hostbootstrap doctor` validates and idempotently installs only what the
substrate plus the project's [`hostbootstrap.dhall`](schema.md) actually
require. Re-running on a healthy host is a no-op.

## Universal

**Passwordless sudo** is a hard prerequisite on every substrate. The tool
needs it for:

* apt installs (Docker, GPU drivers, NVIDIA container toolkit) on Linux.
* Docker group/runtime configuration on Linux.
* brew installs (Tart, ghcup) on macOS.
* Creating and destroying **system-level** service units (a system-scope
  systemd unit in `/etc/systemd/system` on Linux; a **LaunchDaemon** in
  `/Library/LaunchDaemons` on macOS) — but **only** for the
  [host-daemon model](schema.md). No other model touches a system unit, so on a
  pure container or host-binary project the unit-creation reason simply does not
  apply; the apt/brew and Docker/GPU reasons above still do.

Missing passwordless sudo is a fail-fast condition with precise remediation.

### Why a unit is daemon-gated

A system service unit is created **if and only if** a substrate uses the
host-daemon execution model — that model exists precisely to wrap a
long-running host-native daemon in a unit. The container and host-binary models
never create one: a container runs under Docker, and a host binary owns its own
service lifecycle (any unit it installs is the binary's concern, not the tool's).
See [schema.md](schema.md) for the structural rule that makes a unit
unrepresentable for the other two models.

## Dhall parsing (`dhall-to-json`)

Reading `hostbootstrap.dhall` needs `dhall-to-json`, but this is **not** a new
manual prerequisite. The tool auto-provisions a native binary on first use: it
**always** downloads a pinned, SHA256-verified static release into
`~/.cache/hostbootstrap/` and uses that one exclusively. A `dhall-to-json` found
on `PATH` is deliberately **ignored** — pinning the binary keeps config parsing
reproducible and immune to whatever the host happens to have installed.

> **WRONG**
>
> ```sh
> brew install dhall-json   # then expect hostbootstrap to use it
> ```
>
> hostbootstrap never consults `PATH` for `dhall-to-json`, so a host install has
> no effect — and worse, would make parsing depend on an unpinned, unverified
> version.
>
> **RIGHT**
>
> Let hostbootstrap provision its own pinned binary on first use; nothing to
> install.

The one documented gap is **Ubuntu arm64**, which has no prebuilt static asset.
Because the host `PATH` is never used as a fallback, this is a hard fail-fast
condition: provisioning errors out, and the remediation is to build `dhall-json`
from source for that platform.

## apple-silicon

* macOS arm64.
* Xcode Command Line Tools.
* Homebrew.
* Tart + Metal tooling (required exactly when the resolved target is
  `H.Accel.Metal`, which only ever resolves on Apple silicon — there is no
  per-host `tart`/`metal` flag to set).
* ghcup + pinned GHC/Cabal (when a host-binary build is needed).
* FileVault disabled in production mode, so a remote reboot can reach SSH and
  system services without a first interactive unlock.
* **Colima-backed Docker VM configured to start at the system level
  (before user login) in production mode.** hostbootstrap does not install or
  modify Colima — it validates that a bootstrapped system-domain LaunchDaemon
  under `/Library/LaunchDaemons` starts Colima in foreground mode, either
  directly with `colima start -f` / `colima start --foreground` or through a
  wrapper script containing that foreground start. The LaunchDaemon label and
  plist filename do not need to be `com.colima.default`.

Development mode is an explicit opt-in in
[`hostbootstrap.dhall`](schema.md#top-level-shape). On Apple Silicon it keeps
the macOS, Xcode CLT, Homebrew, passwordless-sudo, Docker reachability, and
declared host-build checks, but skips the FileVault and system-Colima
pre-login checks. Use it only for local development hosts where post-reboot
operation before GUI login is not part of the contract.

## linux-cpu

* Ubuntu 24.04.
* Docker installed with non-sudo group access.

## linux-gpu

Everything from linux-cpu, plus:

* NVIDIA driver.
* NVIDIA container toolkit, registered with the Docker runtime.
* Reboot prompted (and exit) when a fresh driver/docker install requires one.

## Headless remote SSH

On macOS production-mode hostbootstrap-configured services must work in setups where
FileVault is off and the user may reboot remotely and SSH in **before any GUI
login**. The Colima VM and any host-daemon unit therefore start at the
system level — a **LaunchDaemon**, never a per-user **LaunchAgent**. User-scope
launchd agents and user-scope systemd units would not survive that workflow.
(This applies only when the host-daemon model is in play; container and
host-binary projects create no unit at all.)

The doctor check enforces both sides of that workflow: FileVault must report
`FileVault is Off.`, and Colima must be represented by a loaded
`system/<label>` launchd service. A per-user LaunchAgent, an unloaded plist, or
a LaunchDaemon that omits `RunAtLoad` is rejected.

Development mode skips those two pre-login checks and never creates or removes
HostDaemon LaunchDaemon/systemd units. It does not waive Docker reachability,
substrate detection, or declared build prerequisites.
