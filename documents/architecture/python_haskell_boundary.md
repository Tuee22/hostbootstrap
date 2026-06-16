# Python / Haskell Boundary

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [build_and_run_model](build_and_run_model.md), [binary_context_config](binary_context_config.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [resource_budgeting](../engineering/resource_budgeting.md), [self_update](../engineering/self_update.md)

> **Purpose**: Define exactly what the thin Python bootstrapper owns versus what
> `hostbootstrap-core` owns, and the rule that new host logic defaults to Haskell.

## TL;DR

- The Python bootstrapper does only the **minimum to build the project binary**: derive the project name
  from the Cabal file, assert the fail-fast host minimums, ensure the host build toolchain, build
  host-native, then exec.
  **Those host minimums are the only hard fail-fast surface in the system.**
- Once the binary runs it is **never blocked by an absent-but-installable dependency** — the `ensure`
  suite installs whatever it needs (install-and-verify; see
  [ensure_reconcilers](../engineering/ensure_reconcilers.md)). The binary also owns the **full
  downstream resource lifecycle**: Docker, the project container, the cordon, the VM provider, the kind
  cluster, the webservice, the Playwright e2e run, and **teardown**.
- Everything else — host-tool resolution, `ensure` reconcilers, substrate detection,
  binary-context validation, nested context creation, cluster lifecycle, and the command tree — lives in
  `hostbootstrap-core` and the project binary.
- New host logic defaults to Haskell. A Python addition must be justified by the pre-binary
  bootstrapping constraint: the host build toolchain must exist before the binary can be built
  host-native. Ensuring Docker and building the project container are **not** pre-binary work — the
  execed binary owns them.
- The bootstrapper may own an explicit self-update command for its own pipx installation. That command
  is distribution lifecycle, not host-management logic; it is never automatic and never a hidden
  latest-version gate for `doctor`, `build`, `run`, or `base`.

> **Current status.** Python now derives `<project>` from the Cabal file, builds
> `./.build/<project>` host-native on every substrate, and execs without reading or writing Dhall. The
> Haskell/project-binary runtime surface owns default `<project>.dhall` generation, child-config
> projection, and normal command gating through the sibling project config. See
> [DEVELOPMENT_PLAN Phase 8](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md),
> [Phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md), and
> [Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md). The explicit
> `hostbootstrap update` command is implemented in Phase 6.5 and documented in
> [self_update](../engineering/self_update.md).

## Ownership Matrix

| Concern | Owner | Why |
|---------|-------|-----|
| Fail-fast host minimums | Python | The **only** hard fail-fast surface in the system — the irreducible host floor the wrapper cannot install; see [prerequisites](../engineering/prerequisites.md). |
| Ensure the host **build** toolchain | Python | The prerequisites to build the binary host-native must exist first — on Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on Linux. |
| Derive project name | Python | The project name comes from the Cabal file name, for example `hostbootstrap-demo.cabal` -> `hostbootstrap-demo`; this is the only project metadata Python needs before the binary exists. |
| Build the project binary **host-native** | Python | A Linux ELF cannot exec on a general host, so the binary is built for the host it runs on into `./.build/<project>`; see [build_and_run_model](build_and_run_model.md). |
| Create or edit the local `<project>.dhall` | Project binary / user | The built binary exposes config initialization, schema, inspection, and upgrade surfaces; Python does not read or write Dhall. See [binary_context_config](binary_context_config.md). |
| Ensure a default `<project>.dhall` exists after the build | Python *triggers*, project binary *writes* | Python runs the just-built binary's idempotent `config init --if-missing` so a default `./.build/<project>.dhall` is always present; the binary owns and writes the Dhall, Python never reads or writes it. |
| Exec the binary | Python | Hands control to the project binary, which owns everything afterward — Docker, the project container, the cordon, and the cluster. |
| Bootstrapper self-update | Python | Updates the pipx-installed wrapper itself through an explicit operator command; it is not an `ensure` reconciler and must not run automatically. See [self_update](../engineering/self_update.md). |
| Ensure Docker + build the project container | `hostbootstrap-core` (the execed binary) | **Not** pre-binary work; the binary does it via `ensure docker` and its container build, gating on `check-code`. See [build_and_run_model](build_and_run_model.md). |
| Host-tool resolution (`HostTool` to absolute paths) | `hostbootstrap-core` | Typed, closed enumeration; no `$PATH` resolution. |
| `ensure` reconcilers (docker/colima/cuda/homebrew/ghc/tart) | `hostbootstrap-core` | Idempotent reconcilers with host-applicability predicates. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| Substrate detection | `hostbootstrap-core` | `apple-silicon`, `linux-cpu`, `linux-gpu`. |
| Binary-context validation and command gating | `hostbootstrap-core` / project binary | Normal commands fail fast when the sibling `<project>.dhall` is missing or incompatible with the requested command. |
| Dhall config initialization and downstream projection | Project binary | The project binary renders defaults, validates local config, and generates narrower child configs at VM/container/service boundaries. See [dhall_topology](../engineering/dhall_topology.md). |
| Resource budgeting and cordoning | `hostbootstrap-core` | Verify spare resources; cordon via Colima sizing / kind limits. See [resource_budgeting](../engineering/resource_budgeting.md). |
| Cluster lifecycle | `hostbootstrap-core` (the execed binary) | kind/Helm semantics, never-delete-`.data` invariant; the lifecycle runs where the context says it may run. In the demo deploy, the lifted operation is `test all`, and the harness calls `clusterUp` locally inside that context. See [cluster_lifecycle](../engineering/cluster_lifecycle.md), [composition_methodology](composition_methodology.md), and [binary_context_config](binary_context_config.md). |
| VM lifecycle (create/exec/copy/destroy, name-guarded) | `hostbootstrap-core` (the execed binary) | The host-provider axis: Apple Silicon demo uses Lima; native Linux uses Incus. The binary spins, sizes, and tears down the VM through the selected provider. See [incus](../engineering/incus.md). |
| Webservice + e2e (serve, Playwright) | `hostbootstrap-core` (the execed binary / its container) | The binary/container serve the webservice and run the Playwright e2e against it. |
| Teardown / spin-down | `hostbootstrap-core` (the execed binary) | The binary owns spinning every resource back down, preserving host `.data`. |
| The optparse command tree | `hostbootstrap-core` | `runHostBootstrapCLI progName projectSpec` is the entrypoint project binaries extend; `ProjectSpec` carries the project commands, non-empty test suite, code-check action, and artifacts. See [hostbootstrap_core_library](hostbootstrap_core_library.md). |

## The Bootstrap Sequence

The Python bootstrapper runs a fixed, minimal sequence — only what must run *before any project
binary exists*:

1. Derive `<project>` from the Cabal file name, failing fast on ambiguity unless the user provides an
   explicit Cabal file.
2. Assert fail-fast host minimums.
3. Ensure the host build toolchain (on Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on
   Linux) — the prerequisites to build the binary host-native. Each tool is **probed first**
   (a quiet, offline `ghcup whereis …` / `ghcup --version`) and installed only when absent, so an
   already-provisioned host makes no network call and prints nothing on the common path.
4. Build the project binary host-native into `./.build/<project>`.
5. Trigger the binary's idempotent `config init --if-missing` so a default `./.build/<project>.dhall`
   always exists. The binary writes the Dhall; Python does not. The mode is a no-op when a config (for
   example a user-edited one) is already present, so it never clobbers existing settings.
6. Exec the binary, handing control to `hostbootstrap-core`'s command tree extended by the project.
   The binary then ensures Docker, builds the project container, applies the cordon, and drives the
   cluster — everything a built binary can reasonably do. If the requested command needs config and
   `./.build/<project>.dhall` is absent (for example it was deleted), the binary still fails fast and
   points the user to `config init`.

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

The explicit `hostbootstrap update` surface is the narrow exception that proves the boundary: it does
not manage a project resource and does not belong in the project binary, because it replaces the
pipx-installed Python wrapper itself. It still follows the thin-layer rule: no Docker, Dhall, VM,
cluster, or cordon logic, and no automatic latest-version check in normal commands.
