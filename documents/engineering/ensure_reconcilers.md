# Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [prerequisites](prerequisites.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [resource_budgeting](resource_budgeting.md)

> **Purpose**: Define the `ensure` reconciler contract — idempotent host-dependency reconcilers
> exposed as optparse subcommands that fail fast on the wrong host.

## TL;DR

- **The `ensure` suite exists so the project binary is never blocked by a host dependency that simply
  isn't installed.** Each host dependency is an idempotent `ensure` reconciler that **installs** it when
  absent and is a verified no-op when present (install-and-verify) — an absent-but-installable
  dependency is installed, not a hard stop.
- The **only** hard fail-fast surface in the whole system is the Python wrapper's host minimums (the
  irreducible host floor it cannot install; see [prerequisites](prerequisites.md)). Everything else
  (Docker, incus, the NVIDIA container toolkit, …) is installed by the `ensure` suite when the binary
  runs.
- Each reconciler is an `optparse-applicative` subcommand (`ensure docker`, `ensure colima`, …) on the
  `hostbootstrap-core` command tree. The *one* fail-fast inside the suite is a **wrong-host misuse**
  (e.g. `ensure tart` on Linux) — a one-line diagnostic and a non-zero exit — which is an operator
  error, **not** an absent dependency.

## Reconciler Contract

A reconciler is a value, not a free function, and carries two parts:

- a **host-applicability predicate** over the detected substrate (`apple-silicon`, `linux-cpu`,
  `linux-gpu`); and
- a **reconcile action** that brings the host to the desired state and is safe to re-run.

Idempotence is required: running a reconciler when the host is already in the desired state is a
successful no-op. The point of the suite is that a **missing** dependency is **never** a hard stop for
the project binary — the reconcile action installs it (see *Install-and-Verify* below). Running a
reconciler on a host where the applicability predicate is false is a fail-fast error, not a quiet skip —
this surfaces operator mistakes (for example, asking for `ensure tart` on Linux) instead of hiding them.
That wrong-host fail-fast is the **only** fail-fast the suite performs, and it is a misuse signal, not an
absent-dependency signal; the only other hard prerequisites in the system are the Python wrapper's host
minimums (see [prerequisites](prerequisites.md)).

Reconcilers live under `HostBootstrap.Ensure.*` and are surfaced on the command tree described in
[hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md). Every external tool a
reconciler drives is resolved through the closed `HostTool` enumeration to an absolute path.

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
down by `brew`) is discoverable by the next step. The install plan is a **pure** function of the
substrate — Homebrew formulae on `apple-silicon`; `apt-get`/`ghcup`/the NVIDIA container toolkit on
Linux — so it is unit-tested without invoking the package manager; the IO driver is exercised during
real bootstrap runs.

| Reconciler | Probe | Install plan (per substrate) |
|------------|-------|------------------------------|
| `docker` | `docker info` reachable | Linux: `apt-get install -y docker.io` + enable the daemon. Apple: defer to `ensure colima`. |
| `colima` | installed and `colima status` running | Apple: `brew install colima` + `colima start`. |
| `cuda` | `nvidia-smi -L` reports a GPU and Docker has the `nvidia` runtime | linux-gpu: install `nvidia-container-toolkit`, `nvidia-ctk runtime configure`, restart Docker (the kernel driver is a precondition, not auto-installed). |
| `homebrew` | `brew` resolved | Apple: none — Homebrew is the toolchain root the Python bootstrapper installs pre-binary; an absent `brew` fails fast with the install instruction. |
| `ghc` | host `ghc` resolved | Apple: `brew install ghcup` + `ghcup install ghc`. |
| `tart` | `tart` resolved | Apple: `brew install cirruslabs/cli/tart`. |
| `incus` | host `incus` resolved | Apple: `brew install incus`. Linux: `apt-get install -y incus` + `incus admin init --minimal`. |

## Reconciler Inventory

| Subcommand | Applies to | Fail-fast behavior on wrong host |
|------------|------------|----------------------------------|
| `ensure docker` | all substrates | n/a (Docker is required to build and run the project container; the execed binary's `ensure docker` installs (Linux) or defers to the per-project Colima VM (Apple) and verifies the daemon is reachable). On Apple it also implies the per-project Colima VM exists. |
| `ensure colima` | `apple-silicon` | Errors on Linux: Colima is the macOS Docker substrate; Linux uses native Docker. |
| `ensure cuda` | `linux-gpu` | Errors on `linux-cpu` and `apple-silicon`: no NVIDIA GPU substrate present. |
| `ensure homebrew` | `apple-silicon` | Errors on Linux: Homebrew is the macOS host package manager for the host toolchain; it is the toolchain root the Python bootstrapper installs pre-binary, so `ensure homebrew` verifies its presence and fails fast with the install instruction when it is absent. |
| `ensure ghc` | `apple-silicon` | Errors on Linux: reconciles the Apple host GHC toolchain. The host build toolchain itself is ensured pre-binary by the bootstrapper, since every substrate builds host-native. |
| `ensure tart` | `apple-silicon` | Errors on Linux: Tart hosts a build-only macOS VM for Swift/Metal artifacts; it has no Linux meaning. |
| `ensure incus` | `apple-silicon` and `linux` | Applies on both: `appliesTo = isAppleSilicon || isLinux`. The incus host-provider is meaningful on every host that can run a VM, so this reconciler does not fail fast on either family. See [incus](incus.md). |

`ensure incus` is the **first cross-substrate reconciler** — its applicability predicate spans both
apple-silicon and linux (`appliesTo = isAppleSilicon || isLinux`), where every other reconciler above
applies to a single substrate family.

The `ensure colima` / `ensure ghc` / `ensure homebrew` chain on Apple silicon is exactly the
pre-binary host setup the thin Python bootstrapper drives before the build; see
[python_haskell_boundary](../architecture/python_haskell_boundary.md). `ensure cuda` aligns with the
GPU host requirements tracked in [prerequisites](prerequisites.md).

## Diagnostics

A wrong-host run emits a single diagnostic line naming the reconciler, the detected substrate, and
the substrate it requires, then exits non-zero. Reconcilers do not attempt partial work before
failing the applicability check. The applicability decision is the pure `decide` function in
`HostBootstrap.Ensure`; `runReconciler` is the IO wrapper that performs the stderr write and the
non-zero exit, so the decision is testable without exiting the process.

- **WRONG**: `ensure tart` on `linux-cpu` prints nothing and exits `0`. This is wrong because it
  masks an operator error and lets a build proceed against an environment that cannot satisfy it.
- **RIGHT**: `ensure tart` on `linux-cpu` prints `ensure tart: not applicable on linux-cpu (requires
  apple-silicon)` and exits non-zero.
