# Python / Haskell Boundary

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [resource_budgeting](../engineering/resource_budgeting.md)

> **Purpose**: Define exactly what the thin Python bootstrapper owns versus what
> `hostbootstrap-core` owns, and the rule that new host logic defaults to Haskell.

## TL;DR

- The Python bootstrapper does only what must run *before any project binary exists*.
- Everything else — host-tool resolution, `ensure` reconcilers, substrate detection, the skeletal
  Dhall decoder, cluster lifecycle, and the command tree — lives in `hostbootstrap-core`.
- New host logic defaults to Haskell. A Python addition must be justified by the pre-binary
  bootstrapping constraint: the host build toolchain must exist before the binary can be built
  host-native. Ensuring Docker and building the project container are **not** pre-binary work — the
  execed binary owns them.

> **Current state.** The ownership boundary below is the *target*. Today the Python bootstrapper
> (`python/hostbootstrap/bootstrap.py`) still ensures Docker (a per-project Colima VM sized to the
> budget), builds the project container, and on Linux builds the binary in-container and copies it out;
> only Apple silicon builds host-native. Moving Docker-ensure, the container build, and the cordon to the
> project binary — and building host-native on Linux too — is tracked in
> [DEVELOPMENT_PLAN Phase 6](../../DEVELOPMENT_PLAN/phase-6-base-image-and-thin-python-bootstrapper.md).

## Ownership Matrix

| Concern | Owner | Why |
|---------|-------|-----|
| Fail-fast host minimums | Python | Must pass before anything else runs; see [prerequisites](../engineering/prerequisites.md). |
| Ensure the host **build** toolchain | Python | The prerequisites to build the binary host-native must exist first — on Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on Linux. |
| Build the project binary **host-native** | Python | A Linux ELF cannot exec on a general host, so the binary is built for the host it runs on into `./.build/<project>`; see [build_and_run_model](build_and_run_model.md). |
| Exec the binary | Python | Hands control to the project binary, which owns everything afterward — Docker, the project container, the cordon, and the cluster. |
| Ensure Docker + build the project container | `hostbootstrap-core` (the execed binary) | **Not** pre-binary work; the binary does it via `ensure docker` and its container build, gating on `check-code`. See [build_and_run_model](build_and_run_model.md). |
| Host-tool resolution (`HostTool` to absolute paths) | `hostbootstrap-core` | Typed, closed enumeration; no `$PATH` resolution. |
| `ensure` reconcilers (docker/colima/cuda/homebrew/ghc/tart) | `hostbootstrap-core` | Idempotent reconcilers with host-applicability predicates. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| Substrate detection | `hostbootstrap-core` | `apple-silicon`, `linux-cpu`, `linux-gpu`. |
| Skeletal Dhall decoder | `hostbootstrap-core` | Core decodes only the skeletal schema; rich schemas are project artifacts. See [dhall_topology](../engineering/dhall_topology.md). |
| Resource budgeting and cordoning | `hostbootstrap-core` | Verify spare resources; cordon via Colima sizing / kind limits. See [resource_budgeting](../engineering/resource_budgeting.md). |
| Cluster lifecycle | `hostbootstrap-core` | kind/Helm semantics, never-delete-`.data` invariant. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| The optparse command tree | `hostbootstrap-core` | `runHostBootstrapCLI` is the entrypoint project binaries extend. See [hostbootstrap_core_library](hostbootstrap_core_library.md). |

## The Bootstrap Sequence

The Python bootstrapper runs a fixed, minimal sequence — only what must run *before any project
binary exists*:

1. Assert fail-fast host minimums.
2. Ensure the host build toolchain (on Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on
   Linux) — the prerequisites to build the binary host-native.
3. Build the project binary host-native into `./.build/<project>`.
4. Exec the binary, handing control to `hostbootstrap-core`'s command tree extended by the project.
   The binary then ensures Docker, builds the project container, applies the cordon, and drives the
   cluster — everything a built binary can reasonably do.

## The Default-to-Haskell Rule

New host-management logic is added to `hostbootstrap-core`, not to the Python bootstrapper.

- **WRONG**: add a new host-tool check to the Python layer "because it is convenient." This is wrong
  because it grows the un-typed, un-tested pre-binary surface and duplicates logic the `ensure`
  reconcilers already own.
- **RIGHT**: add the check as an `ensure` reconciler in `hostbootstrap-core`, exposed as an optparse
  subcommand, so it is typed, idempotent, and shared by every consumer.

A Python addition is justified only when the logic must run before the project binary can exist —
the canonical example being that the host build toolchain must be present before the binary can be
built host-native. Ensuring Docker and building the project container are **not** pre-binary work;
the execed binary owns them. When that boundary changes, update this document and the affected phase
plan in the same change.
