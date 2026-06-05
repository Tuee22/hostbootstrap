---
name: engineering-prerequisites
description: Host prerequisites validated by hostbootstrap doctor.
type: reference
---

# Prerequisites

`hostbootstrap doctor` validates what the detected substrate and selected
[`hostbootstrap.dhall`](schema.md) entry require. It does not write
launchd/systemd units, install automatic restart hooks, or validate pre-login
boot behavior. After a reboot, the operator is responsible for calling
`hostbootstrap cluster up` again and running any host daemon foreground process
with `hostbootstrap daemon run`.

## Universal

**Passwordless sudo** is a hard prerequisite. The tool needs it for host package
and Docker setup checks on Linux and for Homebrew/Xcode-adjacent host checks on
macOS.

**Docker reachability** is required for container builds, Linux host-native
builds, and projects that use kind or other Docker-backed cluster tooling.
hostbootstrap checks that the `docker` CLI exists and that `docker info`
succeeds.

## Dhall Parsing

Reading `hostbootstrap.dhall` needs `dhall-to-json`, but this is not a manual
prerequisite. hostbootstrap downloads a pinned, SHA256-verified static binary
into `~/.cache/hostbootstrap/` and uses that one exclusively. A `dhall-to-json`
found on `PATH` is deliberately ignored.

> **WRONG**
>
> ```sh
> brew install dhall-json
> ```
>
> hostbootstrap never consults `PATH` for `dhall-to-json`, so this does not
> affect config parsing.
>
> **RIGHT**
>
> Let hostbootstrap provision its pinned binary on first use.

The known gap is Ubuntu arm64, which has no prebuilt static `dhall-to-json`
asset. Provisioning fails fast there rather than falling back to an ambient host
binary.

## Apple Silicon

- macOS arm64.
- Xcode Command Line Tools.
- Homebrew.
- Docker daemon reachable.
- ghcup, when the selected target uses `HostBinary` or `HostDaemon`.

hostbootstrap does not check FileVault state and does not require Colima to be
installed as a system LaunchDaemon. If an operator wants Docker or a project
daemon to start automatically after reboot, that wrapper belongs outside
hostbootstrap and should run `hostbootstrap daemon run` as the supervised
foreground process.

## Linux CPU

- Ubuntu 24.04.
- Docker installed and reachable by the invoking user.

Host-native Haskell builds still run inside the selected base container on Linux,
so host GHC/Cabal are not required.

## Linux GPU

Everything from Linux CPU, plus:

- NVIDIA driver.
- NVIDIA container toolkit registered with Docker.

The `linux-gpu` substrate selects the CUDA base-image flavor.
