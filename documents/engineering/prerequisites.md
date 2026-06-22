# Prerequisites

**Status**: Authoritative source
**Supersedes**: prior host-prerequisite notes without metadata
**Referenced by**: [../README.md](../README.md), [schema.md](schema.md), [base_image.md](base_image.md)

> **Purpose**: Define the small set of host minimums the thin Python bootstrapper asserts fail-fast
> before any project binary exists, and point everything else at the Haskell `ensure` reconcilers.

## TL;DR

- The Python bootstrapper asserts a **minimal, fail-fast** set of host minimums — only what must hold
  before the project binary can be built. **These minimums are the only hard fail-fast surface in the
  whole system.**
- Everything beyond those minimums (Docker, Colima, CUDA, Homebrew packages, GHC, Tart, incus) is
  **installed by Haskell `ensure` reconcilers** when the binary runs (install-and-verify), so the binary
  is **never blocked by an absent-but-installable dependency**. See
  [ensure_reconcilers.md](ensure_reconcilers.md).
- A missing *minimum* aborts with a one-line diagnostic and a non-zero exit; it is never worked around.
  (A reconciler's only fail-fast is a wrong-host misuse, never mere absence.)
- Bootstrapper freshness is not a host minimum. Normal commands do not check whether the pipx-installed
  wrapper is at the latest commit; self-update is explicit and documented in [self_update.md](self_update.md).

## Why The Split

The Python layer runs *before any project binary exists*, so it can only depend on the host shell
and a handful of system tools. Its job is to assert the host is bootstrappable, ensure the host build
toolchain, build the project binary host-native into `./.build/<project>`, and exec it. The fail-fast
minimums below are the preconditions for that pre-binary work. All richer
host-management logic lives in `hostbootstrap-core` as `ensure` reconcilers and runs through the
project binary (or `hostbootstrap-core`'s own bare binary).

## Linux Minimums

The Python bootstrapper asserts, fail-fast:

- **Ubuntu 24.04.** The supported Linux substrate (`linux-cpu` and `linux-gpu`).
- **Passwordless sudo.** Required for the host package and Docker setup the `ensure` reconcilers
  perform.

Docker itself is **not** a Python minimum on Linux; `ensure docker` provisions it, starts the daemon,
grants the invoking user `docker` socket access for future login sessions, applies an immediate socket
ACL when the current process has not observed refreshed groups yet, and verifies that access.
GPU specifics (NVIDIA driver, container toolkit) are reconciled by `ensure cuda`, not asserted here.

## Apple Silicon Minimums

The Python bootstrapper asserts, fail-fast:

- **Passwordless sudo.**
- **Xcode Command Line Tools.**
- **Homebrew.**

These three are the bedrock the Apple bootstrap path needs before it can ensure anything else.
Homebrew is the channel through which the bootstrapper installs the host GHC/Cabal toolchain
(`ghcup`) needed to build the binary host-native, so Homebrew's own presence must be a hard
precondition rather than something reconciled. (The Docker provider, `ensure colima`, runs later —
the execed binary owns it, not the pre-binary bootstrapper.)

## Everything Else Is Ensured, Not Required

The following are **not** Python prerequisites; the `ensure` suite **installs** them (install-and-verify)
when the binary runs, so the binary is never blocked by their absence. Each fails fast only on the wrong
host (a misuse), never on mere absence:

| Concern | Reconciler | Applies on |
|---|---|---|
| Docker reachability | `ensure docker` | all substrates |
| Per-project Colima VM | `ensure colima` | Apple silicon |
| Lima pristine demo VM provider | `ensure lima` | Apple silicon |
| Incus host-provider | `ensure incus` | Apple silicon (Colima-backed) and Linux (native daemon) |
| NVIDIA driver + container toolkit | `ensure cuda` | `linux-gpu` |
| Homebrew packages | `ensure homebrew` | Apple silicon |
| Host GHC toolchain | `ensure ghc` | Apple silicon (native host build) |
| Tart build VM | `ensure tart` | Apple silicon (build-only) |

See [ensure_reconcilers.md](ensure_reconcilers.md) for each reconciler's host-applicability
predicate and reconcile action.

## Bootstrapper Freshness Is Not A Minimum

The pipx-installed Python wrapper may be updated explicitly, but being behind the default branch is not
an irreducible host floor. `doctor`, `build`, `run`, and `base` must not contact GitHub to discover
freshness, must not mutate the pipx installation, and must not fail because a newer commit exists.
See [self_update.md](self_update.md).

## Typed Checks In hostbootstrap-core

The fail-fast minimums above are expressed as typed checks in `HostBootstrap.HostPrereqs`, dispatched
by the detected substrate (`HostBootstrap.Substrate`). `checkHostMinimums` runs the labelled checks
in order and stops at the first failure, returning a one-line `PrereqError`. Each check resolves its
external tools through the closed `HostTool` enumeration to absolute paths (`HostBootstrap.HostTool` /
`HostBootstrap.HostConfig`) — no `$PATH`-resolved bare command names. Substrate detection and host-tool
resolution are owned by `hostbootstrap-core`. The pure-Python `prereqs.py` and `substrate.py` are the
thin bootstrapper's fail-fast surface — the irreducible host floor the pre-binary work depends on. The
consolidated host minimums live in `HostBootstrap.HostPrereqs`. See
[hostbootstrap_core_library.md](../architecture/hostbootstrap_core_library.md).

> **WRONG** — treating an ensured tool as a manual host prerequisite
>
> ```sh
> brew install colima
> ```
>
> Manually installing the Docker provider is unnecessary and drifts from the budget-sized,
> per-project VM `ensure colima` provisions. The reconciler owns Colima's lifecycle and sizing.
>
> **RIGHT**
>
> Let the project binary run `ensure colima`, which provisions a per-project VM sized to the
> `resources` budget in [`<project>.dhall`](schema.md).

## See also

- [ensure_reconcilers.md](ensure_reconcilers.md) — the reconcilers that cover everything beyond the
  minimums
- [schema.md](schema.md) — the project-local config the binary reads after it is built
- [base_image.md](base_image.md) — the image the project container is built from
