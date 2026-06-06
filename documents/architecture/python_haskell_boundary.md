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
  bootstrapping constraint: on Apple silicon, Colima must exist before the build can run.

## Ownership Matrix

| Concern | Owner | Why |
|---------|-------|-----|
| Fail-fast host minimums | Python | Must pass before anything else runs; see [prerequisites](../engineering/prerequisites.md). |
| Ensure Docker (provision per-project Colima VM on Apple) | Python | Docker is the one universal build dependency; on Apple the VM must exist before the build. |
| Build the project container (`check-code` gate) | Python | Produces the binary; gates on the project's canonical code-check. See [code_check_doctrine](../engineering/code_check_doctrine.md). |
| Copy the built binary to `./.build/` | Python | Makes the host binary available for exec on every substrate. See [build_and_run_model](build_and_run_model.md). |
| Ensure host runtimes (e.g. host GHC on Apple) | Python | A Linux ELF cannot exec on macOS, so the native build needs a host toolchain in place first. |
| Exec the binary | Python | Hands control to the project binary, which owns everything afterward. |
| Host-tool resolution (`HostTool` to absolute paths) | `hostbootstrap-core` | Typed, closed enumeration; no `$PATH` resolution. |
| `ensure` reconcilers (docker/colima/cuda/homebrew/ghc/tart) | `hostbootstrap-core` | Idempotent reconcilers with host-applicability predicates. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| Substrate detection | `hostbootstrap-core` | `apple-silicon`, `linux-cpu`, `linux-gpu`. |
| Skeletal Dhall decoder | `hostbootstrap-core` | Core decodes only the skeletal schema; rich schemas are project artifacts. See [dhall_topology](../engineering/dhall_topology.md). |
| Resource budgeting and cordoning | `hostbootstrap-core` | Verify spare resources; cordon via Colima sizing / kind limits. See [resource_budgeting](../engineering/resource_budgeting.md). |
| Cluster lifecycle | `hostbootstrap-core` | kind/Helm semantics, never-delete-`.data` invariant. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| The optparse command tree | `hostbootstrap-core` | `runHostBootstrapCLI` is the entrypoint project binaries extend. See [hostbootstrap_core_library](hostbootstrap_core_library.md). |

## The Bootstrap Sequence

The Python bootstrapper runs a fixed, minimal sequence:

1. Assert fail-fast host minimums.
2. Ensure Docker; on Apple silicon, provision the per-project Colima VM sized to the resource budget.
3. Build the project container `FROM` the base image, gating on the `check-code` quality gate.
4. Copy the built binary to `./.build/`.
5. Ensure host runtimes required to run the binary (on Apple, ensure a host GHC toolchain via
   Homebrew so the native build can run).
6. Exec the binary, handing control to `hostbootstrap-core`'s command tree extended by the project.

## The Default-to-Haskell Rule

New host-management logic is added to `hostbootstrap-core`, not to the Python bootstrapper.

- **WRONG**: add a new host-tool check to the Python layer "because it is convenient." This is wrong
  because it grows the un-typed, un-tested pre-binary surface and duplicates logic the `ensure`
  reconcilers already own.
- **RIGHT**: add the check as an `ensure` reconciler in `hostbootstrap-core`, exposed as an optparse
  subcommand, so it is typed, idempotent, and shared by every consumer.

A Python addition is justified only when the logic must run before the project binary can exist —
the canonical example being that Colima must be provisioned before the build step on Apple silicon.
When that boundary changes, update this document and the affected phase plan in the same change.
