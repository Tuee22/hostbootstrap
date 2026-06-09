# Build and Run Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [resource_budgeting](../engineering/resource_budgeting.md)

> **Purpose**: Define the build/run model — why every project binary is built **host-native** into
> `./.build/`, and why building the project container is the binary's job, not the bootstrapper's.

## TL;DR

- Every project produces one host binary at `./.build/<binary>`, built **host-native** on every
  substrate — the same way everywhere.
- A Linux ELF cannot exec on a general host such as Apple silicon, so there is **no**
  build-in-container, copy-out path; the binary is always built for the host it will run on.
- The Python bootstrapper ensures the host **build toolchain** (on Apple, Homebrew → `ghcup` →
  GHC/Cabal; the equivalent on Linux), builds the binary host-native, and execs it.
- Building the **project container** is the execed binary's job, not the bootstrapper's — the binary
  ensures Docker and builds the container `FROM` the base image, gating on the `check-code` code-check.
- Tart is build-only on Apple (Swift/Metal artifacts); no built binary ever runs inside a Tart VM.

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
`./.build/<binary>`; they never reach into a container to run the binary.

## Why `./.build/` Is Always Present

`./.build/<binary>` is the single, stable location every consumer and the test harness exec. Building
it host-native on every substrate means downstream tooling does not branch on substrate to locate or
run the binary. See [python_haskell_boundary](python_haskell_boundary.md) for the bootstrap sequence
that produces it.

## Tart Is Build-Only

Tart hosts a macOS VM used to produce Swift/Metal build artifacts on Apple silicon. Those artifacts
are copied to `./.build/` and run on the host. No built binary ever runs inside the Tart VM; the VM
is a build environment, not a runtime. The `ensure tart` reconciler therefore fails fast on Linux —
see [ensure_reconcilers](../engineering/ensure_reconcilers.md).

## The Project Container Is the Binary's Job

The Python bootstrapper does **not** ensure Docker or build the project container. Once the
host-native binary is built and execd, the **binary** does that work, because it can do everything a
built binary reasonably can:

- **Ensure Docker**: the binary's `ensure docker` reconciler provisions and verifies Docker (on Apple,
  the per-project Colima VM sized to the resource budget). See
  [resource_budgeting](../engineering/resource_budgeting.md).
- **Build the project container** `FROM` the base image, gating on the project's canonical code-check
  (formatting, lint, type/compile checks). Building the container is the mechanism that enforces this
  gate. See [code_check_doctrine](../engineering/code_check_doctrine.md).

The two builds are distinct and owned by distinct layers: the bootstrapper's host-native binary build
(the prerequisite to having any binary at all) and the binary's later container build (the code-check
gate and any container-resident services). Neither is redundant — collapsing them would either skip
the gate or ship an unrunnable binary.
