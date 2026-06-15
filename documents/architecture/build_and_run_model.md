# Build and Run Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [resource_budgeting](../engineering/resource_budgeting.md), [binary_context_config](binary_context_config.md)

> **Purpose**: Define the build/run model — why every project binary is built **host-native** into
> `./.build/`, and why building the project container is the binary's job, not the bootstrapper's.

## TL;DR

- Every project produces one host binary at `./.build/<binary>`, built **host-native** on every
  substrate — the same way everywhere.
- A Linux ELF cannot exec on a general host such as Apple silicon, so there is **no**
  build-in-container, copy-out path; the binary is always built for the host it will run on.
- The Python bootstrapper derives the project name from the Cabal file, ensures the host **build
  toolchain** (on Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on Linux), builds the binary
  host-native, and execs it.
- Building the **project container** is the execed binary's job, not the bootstrapper's — the binary
  ensures Docker and builds the container `FROM` the base image, gating on the `check-code` code-check.
- Tart is build-only on Apple (Swift/Metal artifacts); no built binary ever runs inside a Tart VM.

> **Current status.** The host-native, no-copy-out model is implemented. Python no longer writes any Dhall
> file after the build; the built binary creates or validates its sibling `<project>.dhall`. Ensuring
> Docker, building the project container, and the cordon are owned by the execed binary, not the
> bootstrapper. The original convergence
> to the host-native model is recorded in
> [DEVELOPMENT_PLAN Phase 6](../../DEVELOPMENT_PLAN/phase-6-base-image-and-thin-python-bootstrapper.md);
> the project-local config handoff is recorded in
> [Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md).

## Why the binary is built host-native

A `hostbootstrap` binary is a native executable for one OS/arch. A binary built inside a Linux
container is a Linux ELF; it cannot exec on a general host such as Apple silicon. Earlier designs
built the binary in the project container and copied it out — that was abandoned for exactly this
reason. Every substrate now builds the binary **host-native**, for the host it will run on:

| Substrate | Where the binary is built | Where it runs | Why |
|-----------|---------------------------|---------------|-----|
| `linux-cpu` / `linux-gpu` | Host-native (the bootstrapper ensures the host GHC/Cabal toolchain) | On the host | The binary is built directly for the host; no container round-trip. |
| `apple-silicon` | Host-native (the bootstrapper ensures a host GHC toolchain via Homebrew → `ghcup`) | On the host | A Linux ELF cannot exec on macOS, so the runnable binary must be a native macOS build. |

In all cases the result is a `./.build/<binary>` host executable. Consumers and the test harness run
`./.build/<binary>`; they never reach into a container to run the host binary. Normal command dispatch
requires the sibling `./.build/<project>.dhall`, created by the built binary's config initialization
surface rather than by Python — which the bootstrapper triggers idempotently (`config init --if-missing`)
right after the build, so the default is normally already present.

## Why `./.build/` Is Always Present

`./.build/<binary>` is the single, stable location every consumer and the test harness exec. Building
it host-native on every substrate means downstream tooling does not branch on substrate to locate or
run the binary. See [python_haskell_boundary](python_haskell_boundary.md) for the bootstrap sequence
that produces it.

The bootstrapper populates that path with a plain, incremental `cabal build exe:<project>` (not
`cabal install`): it asks cabal for the freshly built executable's path under `dist-newstyle/` via
`cabal list-bin exe:<project>` and copies it to `./.build/<project>`. `cabal build` is incremental and,
on an unchanged rerun, prints just `Up to date` — it does not re-package each local source into an
sdist tarball, re-resolve the plan, or copy the exe on every invocation the way `cabal install` does,
so a warm `hostbootstrap run` is quiet while a genuine cold build still shows live compile progress.
This mirrors the in-container build, which already uses `cabal build` + `list-bin`.

## Where the host build cache lives

The host-native `cabal build` keeps its package store **repo-local** at `./.build/cabal-store/`
(passed as cabal's global `--store-dir`), not in the user-global store at
`~/.local/state/cabal/store/`. Because `./.build/` is git-ignored, `git clean -fxd` resets the **full**
host build state — the compiled dependency closure included — so a cleaned tree rebuilds cold rather
than silently reusing deps from a shared user store. This is the host build's store only; it is
distinct from, and shares nothing with, the in-container warm store at `/opt/cache/cabal/` that the
later project-container build reuses (see [warm_store.md](../engineering/warm_store.md)).

## Tart Is Build-Only

Tart hosts a macOS VM used to produce Swift/Metal build artifacts on Apple silicon. Those artifacts
are copied to `./.build/` and run on the host. No built binary ever runs inside the Tart VM; the VM
is a build environment, not a runtime. The `ensure tart` reconciler therefore fails fast on Linux —
see [ensure_reconcilers](../engineering/ensure_reconcilers.md).

## The Project Container Is the Binary's Job

The Python bootstrapper does **not** ensure Docker or build the project container. Once the
host-native binary is built and execed, the **binary** does that work, because it can do everything a
built binary reasonably can:

- **Ensure Docker**: the binary's `ensure docker` reconciler provisions and verifies Docker (on Apple,
  the per-project Colima VM sized to the resource budget). See
  [resource_budgeting](../engineering/resource_budgeting.md).
- **Build the project container** `FROM` the base image, gating on the project's canonical code-check
  (formatting, lint, type/compile checks). Building the container is the mechanism that enforces this
  gate. The Dockerfile first runs the binary's config initialization surface so the container's normal
  commands read a sibling `/usr/local/bin/<project>.dhall`. See
  [code_check_doctrine](../engineering/code_check_doctrine.md) and
  [binary_context_config](binary_context_config.md).

The two builds are distinct and owned by distinct layers: the bootstrapper's host-native binary build
(the prerequisite to having any binary at all) and the binary's later container build (the code-check
gate and any container-resident services). Neither is redundant — collapsing them would either skip
the gate or ship an unrunnable binary.

## The `HostTarget` Parameterization

A linux-host operation runs against a typed **host target**: the local host or an incus VM. This is a
host-provider axis orthogonal to substrate — the VM is still a `linux-cpu`/`linux-gpu` machine inside,
and the host target is not a fifth run-model. It parameterizes the existing run-models rather than
adding to them:

```
data HostTarget = Local | InVM IncusVM
```

Every linux-host operation runs through one dispatch point, `runInTarget`, against `Local` or `InVM`,
with **no per-call branching** at the call sites. `runInTarget cfg Local t args` runs the resolved
tool directly; `runInTarget cfg (InVM vm) t args` dispatches through one host
`incus exec <name> -- <tool> <args>` into the VM (where the in-VM `<tool>` is the VM's own `$PATH`
binary, since the VM is a separate machine). The run-models in [run_models](run_models.md) are
unchanged; the host target sits underneath them, so the same machinery runs identically whether the
linux host is local or encapsulated in an incus VM. See
[incus](../engineering/incus.md) for the host-provider axis, the `ensure incus` install, and the VM
lifecycle.

The two-case `HostTarget` is the **tool-level** lift; the **subcommand-level self-reference lift**
(`HostBootstrap.Lift`) generalizes it to an n-level context stack (`Local | InVM | InContainer`), where a
binary crosses a boundary by invoking its *own* subcommand in the nested context (`incus exec` for a VM,
`docker run --rm` for a container). See
[composition_methodology](composition_methodology.md).
