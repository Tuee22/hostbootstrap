# Python / Haskell Boundary

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [build_and_run_model](build_and_run_model.md), [binary_context_config](binary_context_config.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [resource_budgeting](../engineering/resource_budgeting.md), [self_update](../engineering/self_update.md)

> **Purpose**: Define exactly what the thin Python bootstrapper owns versus what
> `hostbootstrap-core` owns, frame the bootstrapper as the metal-frame instance of the fractal
> bootstrap, and state the rule that new host logic defaults to Haskell.

## TL;DR

- The Python bootstrapper is the **metal-frame instance of the fractal bootstrap**: it
  **provisions the frame** it runs in (asserts the host minimums, ensures the host build toolchain),
  **builds the project binary** (the `pb`) into that frame, then **hands off** to the binary. That
  provision → build-pb → handoff pattern is the same descent every nested frame performs; the metal
  frame is its outermost, Python-owned instance. The model lives in
  [composition_methodology](composition_methodology.md); this doc only marks where the boundary sits.
- The Python bootstrapper does only the **minimum to build the project binary**: derive the project
  name from the Cabal file, assert the fail-fast host minimums, ensure the host build toolchain, build
  host-native, then exec. **Those host minimums are the only hard fail-fast surface in the system.**
- Once the binary runs it is **never blocked by an absent-but-installable dependency** — the `ensure`
  suite installs whatever it needs (install-and-verify; see
  [ensure_reconcilers](../engineering/ensure_reconcilers.md)). The binary also owns the **full
  downstream lifecycle**: Docker, the project container, the cordon, the VM provider, the kind cluster,
  the webservice, the Playwright e2e run, and **teardown**.
- Everything else — host-tool resolution, `ensure` reconcilers, substrate detection,
  binary-context validation, child-context minting, cluster lifecycle, and the command tree — lives in
  `hostbootstrap-core` and the project binary.
- New host logic defaults to Haskell. A Python addition must be justified by the pre-binary
  bootstrapping constraint: the host build toolchain must exist before the binary can be built
  host-native. Ensuring Docker and building the project container are **not** pre-binary work — the
  execed binary owns them.
- The bootstrapper may own an explicit self-update command for its own pipx installation. That command
  is distribution lifecycle, not host-management logic; it is never automatic and never a hidden
  latest-version gate.

## The Metal Frame Of The Fractal Bootstrap

A `hostbootstrap` system is a chain of execution frames — metal host → VM → project container →
cluster. Each descent into the next frame is the same three-move pattern:

1. **Provision the frame** — make the next context exist and reach "usable".
2. **Build/install the `pb` in that frame** — put a copy of the project binary on its `$PATH`.
3. **Hand off** — invoke the binary in the new frame so it owns its own segment of the chain.

The Python bootstrapper is the **metal-frame instance** of exactly that pattern, with the metal host as
its frame: it provisions the host (asserts the minimums, ensures the build toolchain), builds the `pb`
host-native, and hands off by `exec`-ing it. The recursion then continues entirely in Haskell — the
project binary descends into the VM and container frames the same way.

Two caveats keep the metal frame distinct from the inner frames, and they are exactly the reason Python
exists as a separate thin layer at all:

- The metal-frame **build is parent-orchestrated.** The child `pb` does not exist yet, so the parent
  (Python) must compile it before any binary can run. Inner frames usually skip the build — the
  container frame runs the already-built image (`docker run <image> …`) rather than recompiling.
- The metal frame is the **only** frame whose orchestrator is not the project binary. From the host
  binary inward, every frame is provisioned and handed off by `hostbootstrap-core`, so the rest of the
  chain is one recursive interpreter.

This framing **does not move the ownership boundary**: Python still does only the irreducible pre-binary
work and execs; the binary still owns everything from Docker inward. The fractal lens just names *why*
the boundary falls where it does — the metal frame is the one descent the binary cannot perform on
itself, because at metal there is no binary yet.

## Ownership Matrix

| Concern | Owner | Why |
|---------|-------|-----|
| Fail-fast host minimums | Python | The **only** hard fail-fast surface in the system — the irreducible host floor the wrapper cannot install; see [prerequisites](../engineering/prerequisites.md). |
| Ensure the host **build** toolchain | Python | The prerequisites to build the binary host-native must exist first — on Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on Linux. This is the metal frame's *provision* move. |
| Derive project name | Python | The project name comes from the Cabal file name, for example `hostbootstrap-demo.cabal` -> `hostbootstrap-demo`; this is the only project metadata Python needs before the binary exists. |
| Build the project binary **host-native** | Python | A Linux ELF cannot exec on a general host, so the binary is built for the host it runs on into `./.build/<project>`; this is the metal frame's *build-pb* move. See [build_and_run_model](build_and_run_model.md). |
| Create or edit the local `<project>.dhall` | Project binary / user | The built binary owns config initialization, introspection, and child-context minting; Python does not read or write Dhall. See [binary_context_config](binary_context_config.md). |
| Ensure a default `<project>.dhall` exists after the build | Python *triggers*, project binary *writes* | Python runs the just-built binary's idempotent if-missing init so a default `./.build/<project>.dhall` is always present; the binary owns and writes the Dhall, Python never reads or writes it. |
| Exec the binary | Python | The metal frame's *handoff* move: control passes to the project binary, which owns everything afterward and drives the rest of the fractal descent. |
| Bootstrapper self-update | Python | Updates the pipx-installed wrapper itself through an explicit operator command; it is not an `ensure` reconciler and must not run automatically. See [self_update](../engineering/self_update.md). |
| Ensure Docker + build the project container | `hostbootstrap-core` (the execed binary) | **Not** pre-binary work; the binary does it as chain steps, gating on `check-code`. See [build_and_run_model](build_and_run_model.md). |
| Host-tool resolution (`HostTool` to absolute paths) | `hostbootstrap-core` | Typed, closed enumeration; no `$PATH` resolution. |
| `ensure` reconcilers (docker/colima/cuda/homebrew/ghc/tart) | `hostbootstrap-core` | Idempotent reconcilers with host-applicability predicates, invoked as chain steps. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| Substrate detection | `hostbootstrap-core` | `apple-silicon`, `linux-cpu`, `linux-gpu`. |
| Binary-context validation and command gating | `hostbootstrap-core` / project binary | Each frame fails fast when its sibling `<project>.dhall` does not witness the frame the command belongs in. See [binary_context_config](binary_context_config.md). |
| Child-context minting and downstream projection | Project binary | The binary renders defaults, validates local config, and mints narrower child contexts at the VM/container/service boundaries it descends into. See [dhall_topology](../engineering/dhall_topology.md). |
| Resource budgeting and cordoning | `hostbootstrap-core` | Verify spare resources; cordon via VM sizing / kind limits. See [resource_budgeting](../engineering/resource_budgeting.md). |
| Cluster lifecycle | `hostbootstrap-core` (the execed binary) | kind/Helm semantics, never-delete-`.data` invariant; the cluster is brought up and torn down as chain steps in the frame the context permits. See [cluster_lifecycle](../engineering/cluster_lifecycle.md), [composition_methodology](composition_methodology.md), and [binary_context_config](binary_context_config.md). |
| VM lifecycle (provision/exec/copy/stop/destroy, name-guarded) | `hostbootstrap-core` (the execed binary) | The host-provider axis: Apple Silicon uses Lima; native Linux uses Incus. The binary provisions, sizes, and tears down the VM frame through the selected provider. See [incus](../engineering/incus.md). |
| Webservice + e2e (serve, Playwright) | `hostbootstrap-core` (the execed binary / its container) | The binary/container serve the webservice and run the Playwright e2e against it. |
| Teardown / spin-down | `hostbootstrap-core` (the execed binary) | The binary owns spinning every resource back down on ascent, preserving host `.data`. |
| The optparse command tree | `hostbootstrap-core` | `runHostBootstrapCLI progName projectSpec` is the entrypoint project binaries extend; `ProjectSpec` carries the project's contributed chain, test suite, code-check action, and artifacts. See [hostbootstrap_core_library](hostbootstrap_core_library.md). |

## The Metal-Frame Bootstrap Sequence

The Python bootstrapper runs a fixed, minimal sequence — only what must run *before any project
binary exists* — and it is the provision → build-pb → handoff descent applied to the metal frame:

1. **(Provision)** Derive `<project>` from the Cabal file name, failing fast on ambiguity unless the
   user provides an explicit Cabal file.
2. **(Provision)** Assert fail-fast host minimums.
3. **(Provision)** Ensure the host build toolchain (on Apple, Homebrew → `ghcup` → GHC/Cabal; the
   equivalent on Linux) — the prerequisites to build the binary host-native. Each tool is **probed
   first** (a quiet, offline `ghcup whereis …` / `ghcup --version`) and installed only when absent, so
   an already-provisioned host makes no network call and prints nothing on the common path.
4. **(Build-pb)** Build the project binary host-native into `./.build/<project>`.
5. **(Provision)** Trigger the binary's idempotent if-missing config init so a default
   `./.build/<project>.dhall` always exists. The binary writes the Dhall; Python does not. The mode is a
   no-op when a config (for example a user-edited one) is already present, so it never clobbers existing
   settings.
6. **(Handoff)** Exec the binary, handing control to `hostbootstrap-core`'s command tree extended by the
   project. From here the binary owns the rest of the fractal descent — it ensures Docker, builds the
   project container, applies the cordon, and provisions and hands off into the VM and container frames.
   If a requested command needs config and `./.build/<project>.dhall` is absent (for example it was
   deleted), the binary still fails fast and points the user at config init.

## The Default-to-Haskell Rule

New host-management logic is added to `hostbootstrap-core`, not to the Python bootstrapper.

- **WRONG**: add a new host-tool check to the Python layer "because it is convenient." This is wrong
  because it grows the un-typed, un-tested pre-binary surface and duplicates logic the `ensure`
  reconcilers already own.
- **RIGHT**: add the check as an `ensure` reconciler in `hostbootstrap-core`, invoked as a chain step,
  so it is typed, idempotent, and shared by every consumer.

A Python addition is justified only when the logic must run before the project binary can exist — the
canonical example being that the host build toolchain must be present before the binary can be built
host-native (the metal-frame *build-pb* constraint). Ensuring Docker and building the project container
are **not** pre-binary work; the execed binary owns them. When that boundary changes, update this
document and the affected phase plan in the same change.

The explicit self-update surface is the narrow exception that proves the boundary: it does not manage a
project resource and does not belong in the project binary, because it replaces the pipx-installed
Python wrapper itself. It still follows the thin-layer rule: no Docker, Dhall, VM, cluster, or cordon
logic, and no automatic latest-version check in normal commands. See
[self_update](../engineering/self_update.md).

## Current Status

The ownership boundary described above is implemented today and is **unchanged** by the fractal-bootstrap
framing — the framing is a renaming of the existing handoff, not a behavior change.

- **Implemented today.** Python derives `<project>` from the Cabal file, asserts the host minimums,
  ensures the build toolchain, builds `./.build/<project>` host-native on every substrate, triggers the
  binary's if-missing config init, and execs without reading or writing Dhall. The execed binary owns
  Docker, the container build, the VM provider, the cluster, and teardown. On the Haskell side the
  shipped surface is the **flat verb set** — `ensure`, `config`/`context create`, `cluster`, `test`, and
  the demo's `vm`/`deploy` — and the **self-reference lift** primitive with provider-backed folds for
  Lima and Incus.
- **Target, not yet implemented.** The recursive `project` command (`project init|up|down|destroy`) that
  interprets a project's contributed `chain :: RootConfig -> [Step]` as a single fractal descent is the
  target surface; the flat verbs above become chain steps under it, and `context` becomes read-only
  introspection. The metal-frame role of Python is identical under both surfaces — provision, build the
  `pb`, hand off — so this boundary document is stable across that migration. The `project` command and
  the `[Step]` interpreter are **not** implemented yet; the flat verbs are what runs today. Phase order
  and closure for that migration live in `DEVELOPMENT_PLAN/`, the canonical status authority. See
  [composition_methodology](composition_methodology.md) for the target model.
