# Build and Run Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [resource_budgeting](../engineering/resource_budgeting.md)

> **Purpose**: Define the substrate-dependent build/run model — where each project binary is built,
> why it is always copied to `./.build/`, and why the container is built on every substrate.

## TL;DR

- Every project produces one host binary in `./.build/`, regardless of substrate.
- On Linux the binary is built in the project container and copied out; it runs on the host because
  host and container share the same glibc family.
- On Apple silicon a Linux ELF cannot exec on macOS, so the binary is built natively on the host
  with a host GHC toolchain.
- Tart is build-only (Swift/Metal artifacts); no built binary ever runs inside a Tart VM.
- The container image is built on *every* substrate, both for containerized workflows and as the
  mandatory code-check gate.

## Substrate Build/Run Matrix

| Substrate | Where the binary is built | How it reaches `./.build/` | Where it runs | Why |
|-----------|---------------------------|----------------------------|---------------|-----|
| `linux-cpu` / `linux-gpu` | In the project container (`FROM` the base image) | Copied out of the container | On the host | Host and container share the same glibc family, so the in-container ELF runs unchanged on the host. |
| `apple-silicon` | Natively on the host (Python ensures a host GHC toolchain via Homebrew) | Written directly by the native build | On the host | A Linux ELF cannot exec on macOS, so the runnable binary must be a native macOS build. |

In all cases the result is a `./.build/<binary>` host executable. Consumers never reach into the
container to run the binary; they run `./.build/<binary>`.

## Why `./.build/` Is Always Present

`./.build/<binary>` is the single, stable location every consumer and the test harness exec. Keeping
it populated on every substrate means downstream tooling does not branch on substrate to locate the
binary — only the *build path* differs, not the run path. See
[python_haskell_boundary](python_haskell_boundary.md) for the bootstrap sequence that copies it.

## Tart Is Build-Only

Tart hosts a macOS VM used to produce Swift/Metal build artifacts on Apple silicon. Those artifacts
are copied to `./.build/` and run on the host. No built binary ever runs inside the Tart VM; the VM
is a build environment, not a runtime. The `ensure tart` reconciler therefore fails fast on Linux —
see [ensure_reconcilers](../engineering/ensure_reconcilers.md).

## The Container Is Built on Every Substrate

The project container image is built on every substrate, including Apple silicon where the runnable
binary comes from the native host build instead. Two reasons:

- **Containerized workflows**: Linux substrates run the built binary on the host but still rely on
  the container image for the build itself and for any container-resident services.
- **The code-check gate**: every image build — base or derived — gates on the project's canonical
  code-check (formatting, lint, type/compile checks). Building the container is the mechanism that
  enforces this gate, so it must run even when the host build produces the binary that ships. See
  [code_check_doctrine](../engineering/code_check_doctrine.md).

## The "Build Twice" Rationale

On Apple silicon the work appears to build twice: the container is built (enforcing the code-check
gate and producing any container-resident pieces) and the binary is also built natively on the host
(producing the runnable `./.build/<binary>`). This is intentional. The container build is the
non-negotiable quality gate that runs on every substrate; the native host build exists only because
a Linux ELF cannot exec on macOS. Collapsing the two would either skip the gate or ship an
unrunnable binary, so both builds are kept.
