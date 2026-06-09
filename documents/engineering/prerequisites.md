# Prerequisites

**Status**: Authoritative source
**Supersedes**: the `hostbootstrap doctor` host-prerequisite model and the PATH-ignored `dhall-to-json` provisioning note
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

Docker itself is **not** a Python minimum on Linux; `ensure docker` provisions and verifies it.
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
| NVIDIA driver + container toolkit | `ensure cuda` | `linux-gpu` |
| Homebrew packages | `ensure homebrew` | Apple silicon |
| Host GHC toolchain | `ensure ghc` | Apple silicon (native host build) |
| Tart build VM | `ensure tart` | Apple silicon (build-only) |

See [ensure_reconcilers.md](ensure_reconcilers.md) for each reconciler's host-applicability
predicate and reconcile action.

## Typed Checks In hostbootstrap-core

The fail-fast minimums above are expressed as typed checks in `HostBootstrap.HostPrereqs`, dispatched
by the detected substrate (`HostBootstrap.Substrate`). Each check resolves its external tools through
the closed `HostTool` enumeration to absolute paths (`HostBootstrap.HostTool` /
`HostBootstrap.HostConfig`) — no `$PATH`-resolved bare command names — and returns a one-line
diagnostic on the first unmet minimum. Substrate detection and host-tool resolution are owned by
`hostbootstrap-core`; the pure-Python `prereqs.py` / `substrate.py` are the **retained** pre-binary
minimums implementation (the thin bootstrapper's fail-fast surface — the irreducible host floor), and
the eventual lift of their residual checks into `HostBootstrap.HostPrereqs` is tracked in the
[legacy ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). See
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
> Let the bootstrap path run `ensure colima`, which provisions a per-project VM sized to the
> `resources` budget in [`hostbootstrap.dhall`](schema.md).

## See also

- [ensure_reconcilers.md](ensure_reconcilers.md) — the reconcilers that cover everything beyond the
  minimums
- [schema.md](schema.md) — the static-base config the Python layer reads after the minimums pass
- [base_image.md](base_image.md) — the image the project container is built from
