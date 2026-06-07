# Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [prerequisites](prerequisites.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [resource_budgeting](resource_budgeting.md)

> **Purpose**: Define the `ensure` reconciler contract — idempotent host-dependency reconcilers
> exposed as optparse subcommands that fail fast on the wrong host.

## TL;DR

- Each host dependency is an `ensure` reconciler: an idempotent value with a host-applicability
  predicate and a reconcile action.
- Each reconciler is exposed as an `optparse-applicative` subcommand (`ensure docker`,
  `ensure colima`, …) on the `hostbootstrap-core` command tree.
- A reconciler run on a host it does not apply to fails fast with a one-line diagnostic and a
  non-zero exit; it does not silently no-op.

## Reconciler Contract

A reconciler is a value, not a free function, and carries two parts:

- a **host-applicability predicate** over the detected substrate (`apple-silicon`, `linux-cpu`,
  `linux-gpu`); and
- a **reconcile action** that brings the host to the desired state and is safe to re-run.

Idempotence is required: running a reconciler when the host is already in the desired state is a
successful no-op. Running it on a host where the applicability predicate is false is a fail-fast
error, not a quiet skip — this surfaces operator mistakes (for example, asking for `ensure tart` on
Linux) instead of hiding them.

Reconcilers live under `HostBootstrap.Ensure.*` and are surfaced on the command tree described in
[hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md). Every external tool a
reconciler drives is resolved through the closed `HostTool` enumeration to an absolute path.

## Reconciler Inventory

| Subcommand | Applies to | Fail-fast behavior on wrong host |
|------------|------------|----------------------------------|
| `ensure docker` | all substrates | n/a (Docker is the universal build dependency). On Apple it also implies the per-project Colima VM exists. |
| `ensure colima` | `apple-silicon` | Errors on Linux: Colima is the macOS Docker substrate; Linux uses native Docker. |
| `ensure cuda` | `linux-gpu` | Errors on `linux-cpu` and `apple-silicon`: no NVIDIA GPU substrate present. |
| `ensure homebrew` | `apple-silicon` | Errors on Linux: Homebrew is the macOS host package manager used to provision the host toolchain. |
| `ensure ghc` | `apple-silicon` | Errors on Linux: the host GHC toolchain exists so the native Apple build can run (Linux builds GHC in-container). |
| `ensure tart` | `apple-silicon` | Errors on Linux: Tart hosts a build-only macOS VM for Swift/Metal artifacts; it has no Linux meaning. |

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
