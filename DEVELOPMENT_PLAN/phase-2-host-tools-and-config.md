# Phase 2: Host Floor, Tools, and Config

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-hostbootstrap-core-scaffolding.md](phase-1-hostbootstrap-core-scaffolding.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md)

> **Purpose**: Establish the host floor needed before Haskell validation can run, then lift infernix's
> `HostTools` / `HostConfig` / `HostPrereqs` trio and substrate detection into `HostBootstrap.*`,
> establishing closed-enumeration host-tool resolution and typed substrate detection as the foundation
> the reconcilers build on.

## Phase Status

**Status**: Active

The pre-binary Python host floor and build-toolchain bootstrap, `HostBootstrap.HostTool`,
`HostBootstrap.HostConfig`, `HostBootstrap.HostPrereqs`, and `HostBootstrap.Substrate` are implemented and
unit-tested. Phase 2 owns the cross-language bootstrap dependency that makes the phase order coherent:
on a fresh host, `hostbootstrap build` first asserts only the irreducible pre-binary floor and ensures the
host Haskell build toolchain and Cabal package index, so `cabal build all` / `cabal test` can validate the
Haskell library without depending on a later phase. Host-tool resolution then goes through the closed `HostTool` enumeration to
absolute paths (the `AbsExe` newtype makes a bare command name unrepresentable), and substrate detection
has a pure classification core.

The Windows reopening is closed: native Windows GHC sees
`System.Info.os == "mingw32"`, so `HostBootstrap.Substrate` gains `windows-cpu` / `windows-gpu`
classification (gpu when the NVIDIA CUDA stack is present) and the core's POSIX-only `unix` dependency
is conditionalized at its three call sites so the binary builds host-native on Windows (§ L, § N).

**Reopened 2026-07-09 for accelerator host-tool coverage.** The accelerator daemon's host-resident lanes
need closed-enum tool resolution for Apple Swift/Metal probes and Windows compiler-stack verification. This
does not change the pre-binary host floor; Python still only ensures the Haskell build toolchain before the
project binary exists. The new tools are consumed by Phase 3 reconcilers after the binary is running.

## Remaining Work

**Accelerator host tools — open.** Add closed `HostTool` constructors and discovery tests for the tools the
host daemon ensure logic needs:

- Apple Silicon: `swiftc`, `xcrun`, and the Metal runtime probe command path used to prove a visible Metal
  device and SDK-backed Swift + Metal compile.
- Windows GPU: LLVM `clang`, the MSVC host compiler / Visual Studio Build Tools probe, and any supporting
  resolver needed by `nvcc` host-compiler verification.

Validation: `HostToolSpec` covers absolute-path discovery and missing-tool diagnostics; `SubstrateSpec`
continues to cover the existing substrate classification; Phase 3 integration tests prove these tools are
usable by the daemon build-stack reconcilers.

Previously closed work remains closed. Closed on 2026-06-26 on native Windows: `poetry run python -m hostbootstrap.check_code`,
`poetry run python -m hostbootstrap.test_all` (175 tests), `poetry run hostbootstrap build --project-root
core/hostbootstrap-core` (built `.build/hostbootstrap.exe` after GHCup/GHC/Cabal and `cabal update`),
`cabal build all` from `core/`, and `cabal test all` from `core/` (251 tests). The host reports an NVIDIA
GeForce RTX 3090, covering the real Windows GPU host substrate. WSL2 is intentionally not a Phase-2
pre-binary gate; it is installed/reconciled later by the built binary's Phase-11 `ensure wsl2` provider
path.

## Phase Objective

Establish the pre-binary host floor and build-toolchain bootstrap, then lift the host trio from
[`infernix`](https://github.com/Tuee22/infernix) — the source of
`HostTools` / `HostConfig` / `HostPrereqs` — into `HostBootstrap.*`, and move substrate detection
(`apple-silicon`, `linux-cpu`, `linux-gpu`, and — added when the phase reopened — `windows-cpu` /
`windows-gpu`) into typed Haskell. Establish the host-tool-resolution
doctrine: a closed `HostTool` enumeration resolved to absolute paths, with no `$PATH`-resolved bare
command names (see [development_plan_standards.md § K](development_plan_standards.md)).

## Sprints

### Sprint 2.0: Pre-binary host floor and build-toolchain bootstrap [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `hostbootstrap/prereqs.py`,
`hostbootstrap/substrate.py`, `tests/test_bootstrap.py`, `tests/test_prereqs.py`,
`tests/test_substrate.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/architecture/build_and_run_model.md`, `documents/engineering/prerequisites.md`,
`system-components.md`

#### Objective

Make the repository's numerical development order self-contained on a fresh host: before any Haskell
phase needs `cabal`, the Python bootstrapper can assert the irreducible pre-binary host floor, install or
expose the host Haskell build toolchain, refresh Cabal's package index, and build the native project binary.

#### Deliverables

- `hostbootstrap build` / `hostbootstrap run` assert only the irreducible pre-binary floor: Apple
  Silicon has Xcode CLT + Homebrew, Linux has the OS/sudo floor, and Windows has `winget` as the
  package-manager root. WSL2 is not a pre-binary gate.
- `toolchain_ensure_steps` ensures the Haskell build toolchain before `cabal` is needed: Homebrew ->
  GHCup/GHC/Cabal on Apple, GHCup/GHC/Cabal on Linux, and winget-rooted GHCup/GHC/Cabal on Windows.
- `_build_native` refreshes the Cabal package index (`cabal update`) before the first host-native build
  so a fresh host is not blocked by a missing Hackage package list.
- The built binary owns all post-binary host management: Docker, CUDA, WSL2/Incus/Lima providers,
  project containers, Dhall, cluster lifecycle, and resource cordons.

#### Validation

- Python pure seams and command builders are covered by `tests/test_bootstrap.py`,
  `tests/test_prereqs.py`, and `tests/test_substrate.py`.
- `poetry run python -m hostbootstrap.check_code` passes.
- `poetry run python -m hostbootstrap.test_all` passes.
- Live Windows closure: `hostbootstrap build --project-root core/hostbootstrap-core` installs or exposes
  the Windows Haskell toolchain and builds the native `hostbootstrap.exe`.

#### Remaining Work

None. `poetry run hostbootstrap build --project-root core/hostbootstrap-core` passed on 2026-06-26 and
produced `core/hostbootstrap-core/.build/hostbootstrap.exe`.

### Sprint 2.1: HostTool resolution + HostConfig [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostConfig.hs`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/prerequisites.md`, `system-components.md`

#### Objective

Land `HostBootstrap.HostTool` (the closed `HostTool` enumeration and absolute-path resolution) and
`HostBootstrap.HostConfig` (typed host configuration), lifted from infernix.

#### Deliverables

- `HostBootstrap.HostTool` with a closed `HostTool` sum type and a resolver that returns absolute
  paths from typed configuration; no `proc "<bare-name>"` `$PATH` lookups.
- `HostBootstrap.HostConfig` carrying the typed host configuration the resolver and reconcilers read.

#### Module Surface

- `HostBootstrap.HostTool` — `data HostTool = Docker | Colima | Brew | Ghc | Ghcup | Kubectl | Helm |
  Kind | NvidiaSmi | Sudo | XcodeSelect | …`; the `AbsExe` newtype (absolute-path-only via the
  `mkAbsExe` smart constructor, so a bare command name is unrepresentable) plus `discover`.
- `HostBootstrap.HostConfig` — the typed `HostConfig` (substrate + the resolved `AbsExe` tool paths)
  and `resolve :: HostConfig -> HostTool -> IO AbsExe`, which reads the absolute path from the typed
  configuration (throwing `HostToolError` for an unresolved tool).

#### Validation

- `cabal build all` succeeds.
- `HostToolSpec` asserts resolution returns absolute paths, that `mkAbsExe` rejects bare/relative
  names, and that `resolve` throws `HostToolError` for an unconfigured tool. `cabal test` passes.

#### Remaining Work

None.

### Sprint 2.2: HostPrereqs + substrate detection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs`
**Docs to update**: `documents/engineering/prerequisites.md`, `system-components.md`

#### Objective

Land `HostBootstrap.HostPrereqs` (the typed host-minimum checks) and `HostBootstrap.Substrate`
(substrate detection).

#### Deliverables

- `HostBootstrap.Substrate` detecting `apple-silicon` / `linux-cpu` / `linux-gpu` plus the
  Docker-style arch (`amd64` / `arm64`), pure where the Python original is pure.
- `HostBootstrap.HostPrereqs` carrying the fail-fast host minimums (passwordless sudo, Ubuntu 24.04
  for Linux, Xcode CLT + Homebrew for Apple, Docker reachability, NVIDIA runtime for `linux-gpu`).

#### Validation

- `cabal build all` succeeds.
- `SubstrateSpec` covers each substrate branch through the pure `classify` core; `HostToolSpec`
  covers the `parseOsRelease` / `isUbuntu2404` prerequisite parsing. `cabal test` passes.

#### Remaining Work

None.

### Sprint 2.3: Windows substrate detection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (the conditionalized `unix` dependency),
`core/hostbootstrap-core/test/SubstrateSpec.hs`
**Docs to update**: `documents/engineering/prerequisites.md`,
`documents/architecture/python_haskell_boundary.md`, `system-components.md`

#### Objective

Add Windows as the third metal substrate so `HostBootstrap.Substrate` classifies it as a peer of
apple-silicon and the Linux family, and the core builds host-native on native Windows GHC.

#### Deliverables

- `HostBootstrap.Substrate` classifies `windows-cpu` / `windows-gpu`: native Windows GHC reports
  `System.Info.os == "mingw32"`, and the host is `windows-gpu` when the NVIDIA CUDA stack is present
  (else `windows-cpu`), pure where the classification source is pure.
- The POSIX-only `unix` dependency is conditionalized at its **three** call sites so the closed enum and
  resolver build on Windows; `unix` is dropped from the Windows build and the affected modules take the
  Windows-safe path under `mingw32`.
- `windows-cpu` / `windows-gpu` join the substrate enumeration the reconcilers (§ L) and the host
  prerequisites branch on; the Windows pre-binary floor/toolchain bootstrap is owned by Sprint 2.0.

#### Validation

- `SubstrateSpec` covers the `windows-cpu` / `windows-gpu` branches through the pure `classify` core
  (mingw32 + the GPU-present discriminator); `cabal build all` and `cabal test all` pass with the `unix`
  dependency conditionalized out of the Windows build.

#### Remaining Work

None. `cabal build all` and `cabal test all` passed from `core/` on 2026-06-26 on native Windows; the
host's NVIDIA GeForce RTX 3090 covers the real Windows GPU host.

### Sprint 2.4: Accelerator host-tool coverage [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Extend the closed `HostTool` enumeration so the project binary can run host-resident accelerator ensure
logic without bare `$PATH` calls.

#### Deliverables

- Apple tool coverage for the Swift/Metal build stack: `swiftc`, `xcrun`, and the SDK/runtime probe path
  needed by `ensure-apple-metal`.
- Windows tool coverage for the CUDA daemon build stack: LLVM `clang`, the MSVC host compiler / Visual
  Studio Build Tools probe, and any helper needed to verify `nvcc` can compile a smoke artifact.
- No Python bootstrapper expansion beyond the existing pre-binary Haskell toolchain bootstrap.

#### Validation

- `HostToolSpec` proves each new tool constructor resolves only to absolute paths and fails with the
  standard `HostToolError` when absent.
- Phase 3 integration gates prove the resolved tools can compile the Apple Swift/Metal and Windows CUDA
  daemon workers.

#### Remaining Work

Open until the host-tool constructors, resolver tests, and reconciler integration smoke builds land.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - adds the host-tool-resolution doctrine and
  the substrate-detection ownership statement.
- `documents/architecture/python_haskell_boundary.md` - records the pre-binary host floor and
  toolchain bootstrap that makes Haskell validation available before later phases run.

**Engineering docs to create/update:**
- `documents/engineering/prerequisites.md` - records the fail-fast host minimums and the move of
  richer host logic into Haskell, including the Windows substrate's host floor.

**Cross-references to add:**
- `system-components.md` marks the `HostBootstrap.HostTool` / `HostConfig` / `HostPrereqs` /
  `Substrate` rows present, adds the `windows-cpu` / `windows-gpu` substrates, and tracks the accelerator
  host-tool additions while Sprint 2.4 is active.
