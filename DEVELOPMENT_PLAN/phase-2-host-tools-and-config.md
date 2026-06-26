# Phase 2: Host Tools and Config

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-hostbootstrap-core-scaffolding.md](phase-1-hostbootstrap-core-scaffolding.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md)

> **Purpose**: Lift infernix's `HostTools` / `HostConfig` / `HostPrereqs` trio and substrate
> detection into `HostBootstrap.*`, establishing closed-enumeration host-tool resolution and typed
> substrate detection as the foundation the reconcilers build on.

## Phase Status

**Status**: Active

`HostBootstrap.HostTool`, `HostBootstrap.HostConfig`, `HostBootstrap.HostPrereqs`, and
`HostBootstrap.Substrate` are implemented and unit-tested. Host-tool resolution goes through the
closed `HostTool` enumeration to absolute paths (the `AbsExe` newtype makes a bare command name
unrepresentable), and substrate detection has a pure classification core. The Python bootstrapper keeps
only the residual pre-binary host minimum checks required before a project binary exists.

This phase is **reopened** to add **Windows as the third metal substrate**: native Windows GHC sees
`System.Info.os == "mingw32"`, so `HostBootstrap.Substrate` gains `windows-cpu` / `windows-gpu`
classification (gpu when the NVIDIA CUDA stack is present) and the core's POSIX-only `unix` dependency
is conditionalized at its three call sites so the binary builds host-native on Windows (§ L, § N).

## Remaining Work

Windows substrate detection is the open work — Sprint 2.3 (`[Planned]`). The pure classification and the
conditionalized `unix` dependency are cabal-test-closable; the real-Windows-host detection run is that
sprint's `#### Remaining Work`.

## Phase Objective

Lift the host trio from [`infernix`](https://github.com/Tuee22/infernix) — the source of
`HostTools` / `HostConfig` / `HostPrereqs` — into `HostBootstrap.*`, and move substrate detection
(`apple-silicon`, `linux-cpu`, `linux-gpu`, and — added when the phase reopened — `windows-cpu` /
`windows-gpu`) into typed Haskell. Establish the host-tool-resolution
doctrine: a closed `HostTool` enumeration resolved to absolute paths, with no `$PATH`-resolved bare
command names (see [development_plan_standards.md § K](development_plan_standards.md)).

## Sprints

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

### Sprint 2.3: Windows substrate detection [Planned]

**Status**: Planned
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
  prerequisites branch on; the Windows host floor is winget (§ M), asserted by the Python bootstrapper.

#### Validation

- `SubstrateSpec` covers the `windows-cpu` / `windows-gpu` branches through the pure `classify` core
  (mingw32 + the GPU-present discriminator); `cabal build all` and `cabal test` pass with the `unix`
  dependency conditionalized out of the Windows build.

#### Remaining Work

Real-Windows-host validation (real-run-gated, § C): the pure classification and the conditionalized
`unix` dependency are cabal-test-closable, but observing `windows-cpu` / `windows-gpu` detection and a
host-native `hostbootstrap.exe` build on a real Windows host is this sprint's remaining closure (the
build/exec path is owned by [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md),
the reconcilers by [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md)).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - adds the host-tool-resolution doctrine and
  the substrate-detection ownership statement.
- `documents/architecture/python_haskell_boundary.md` - records the Windows pre-binary host floor
  (winget as the toolchain root) feeding the `windows-cpu` / `windows-gpu` substrate.

**Engineering docs to create/update:**
- `documents/engineering/prerequisites.md` - records the fail-fast host minimums and the move of
  richer host logic into Haskell, including the Windows substrate's host floor.

**Cross-references to add:**
- `system-components.md` marks the `HostBootstrap.HostTool` / `HostConfig` / `HostPrereqs` /
  `Substrate` rows present and adds the `windows-cpu` / `windows-gpu` substrates.
