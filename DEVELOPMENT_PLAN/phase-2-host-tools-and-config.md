# Phase 2: Host floor, tools, and config

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-hostbootstrap-core-scaffolding.md](phase-1-hostbootstrap-core-scaffolding.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md)

> **Purpose**: Establish the host floor needed before Haskell validation can run, then lift infernix's
> `HostTools` / `HostConfig` / `HostPrereqs` trio and substrate detection into `HostBootstrap.*`,
> establishing closed-enumeration host-tool resolution and typed substrate detection as the foundation
> the reconcilers build on.

## Phase Status

**Status**: Done

**Reopened and closed 2026-07-29 for the pre-binary C build libraries (Sprint 2.6).** The first native Linux **CPU**
lane run on a genuinely pristine Ubuntu 24.04 host proved the metal frame's toolchain bootstrap
incomplete: it installs GHCup/GHC/Cabal but not the C libraries GHC and the project's dependency closure
link against, so `hostbootstrap run` died with `Missing (or bad) C library: z`. The fix has landed and is
validated, and the native Linux CPU lane that consumes it reported `10/10` the same day.

**Reopened 2026-07-24 and closed 2026-07-25.** Sprint 2.5 corrected the confirmed
host-tool-boundary and pre-binary prerequisite defects.

The pre-binary Python host floor and build-toolchain bootstrap, `HostBootstrap.HostTool`,
`HostBootstrap.HostConfig`, `HostBootstrap.HostPrereqs`, and `HostBootstrap.Substrate` exist and are
unit-tested and form the completed boundary. Production host-process call sites use resolved executables;
the source regression scan rejects bare literal process targets. The Haskell `HostPrereqs` mirror no
longer includes Docker/KVM/NVIDIA runtime checks assigned to `ensure docker` / `ensure incus` /
`ensure cuda`. Phase 2 owns the cross-language
bootstrap dependency that makes the phase order coherent: on a fresh host, `hostbootstrap build` first
asserts only the irreducible pre-binary floor and ensures the host Haskell build toolchain and Cabal
package index, so `cabal build all` / `cabal test` can validate the Haskell library without depending on a
later phase. The target host-tool contract is a closed `HostTool` enumeration resolved to absolute
`AbsExe` values; substrate detection already has a pure classification core.

The Windows reopening is closed: native Windows GHC sees
`System.Info.os == "mingw32"`, so `HostBootstrap.Substrate` gains `windows-cpu` / `windows-gpu`
classification (gpu when the NVIDIA CUDA stack is present) and the core's POSIX-only `unix` dependency
is conditionalized at its three call sites so the binary builds host-native on Windows (§ L, § N).

**Reopened and closed 2026-07-09 for accelerator host-tool coverage.** The accelerator daemon's
host-resident lanes now have closed-enum tool resolution for Apple Swift/Metal probes and Windows
compiler-stack verification. This does not change the pre-binary host floor; Python still only ensures the
Haskell build toolchain before the project binary exists. The new tools are consumed by Phase 3
reconcilers after the binary is running.

## Remaining Work

None.

The accelerator host tools are implemented as closed `HostTool` constructors and covered by
`HostToolSpec`: Apple Silicon has `Swiftc`, `Xcrun`, and `SystemProfiler`; Windows GPU has `Clang`,
`MsvcCl`, and `Vswhere` alongside the existing `Nvcc`/`NvidiaSmi`. Discovery remains absolute-path-only,
Windows has deterministic fallbacks for `nvcc`, LLVM clang, MSVC `cl.exe`, and `vswhere.exe`, and missing
accelerator tools use the standard `HostToolError` diagnostic. Phase 3 remains responsible for consuming
those resolved tools in the Apple Metal and hardened Windows CUDA reconcilers.

Validation: `cabal test all` passed from `core/` on 2026-07-09 with 309 tests; `HostToolSpec` covers the
new constructors, absolute-path resolution, and missing-tool diagnostics, while `SubstrateSpec` continues
to cover the existing substrate classification.

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
- `toolchain_ensure_steps` ensures the Haskell build toolchain before `cabal` is needed: Homebrew →
  GHCup/GHC/Cabal on Apple, GHCup/GHC/Cabal on Linux, and the initial PowerShell-retrieved
  GHCup/GHC/Cabal path on Windows. Sprint 2.5 owns download pinning/integrity.
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

- `HostBootstrap.HostTool` with a closed `HostTool` sum type and a resolver that returns absolute paths
  from typed configuration. This Sprint 2.1 landing made bare names unrepresentable at migrated call
  sites; it did not prove that every later production host-process launch uses the resolver. Sprint 2.5
  owns that repository-wide closure.
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
- **Historical Sprint 2.2 landing:** `HostBootstrap.HostPrereqs` ported the fail-fast host checks then in
  scope, including Docker reachability and the `linux-gpu` NVIDIA runtime. Those runtime checks (and the
  Linux KVM check subsequently added to the same module) are not the current pre-binary boundary:
  `ensure docker`, `ensure incus`, and `ensure cuda` own them. Sprint 2.5 removes that obsolete duplication
  from the host-minimum mirror.

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

### Sprint 2.4: Accelerator host-tool coverage [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Extend the closed `HostTool` enumeration so the project binary can run host-resident accelerator ensure
logic without bare `$PATH` calls.

#### Deliverables

- Apple tool coverage for the Swift/Metal build stack: `Swiftc`, `Xcrun`, and `SystemProfiler` (the
  visible-Metal runtime probe path) for `ensure-apple-metal`.
- Windows tool coverage for the CUDA daemon build stack: `Clang`, `MsvcCl`, `Vswhere`, and the existing
  `Nvcc`/`NvidiaSmi` constructors needed to verify `nvcc` can compile a smoke artifact with the MSVC host
  compiler.
- No Python bootstrapper expansion beyond the existing pre-binary Haskell toolchain bootstrap.

#### Validation

- `HostToolSpec` proves each new tool constructor resolves only to absolute paths and fails with the
  standard `HostToolError` when absent.
- `cabal test all` passed from `core/` on 2026-07-09 with 309 tests.
- Phase 3 integration gates consume the resolved tools to compile the Apple Swift/Metal and Windows CUDA
  daemon workers.

#### Remaining Work

None. Reconciler integration smoke builds are owned by Phase 3 Sprint 3.6.

### Sprint 2.5: Close the host-tool and pre-binary boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostConfig.hs`, all Haskell host-process call sites,
`hostbootstrap/prereqs.py`, `hostbootstrap/bootstrap.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/prerequisites.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make the closed `HostTool` boundary true at every host-process call site and make the Python host floor
match the commands the bootstrapper actually executes.

#### Deliverables

- Inventory every host-side process launch and route it through an absolute `AbsExe` resolved from the
  closed `HostTool` enumeration; nested guest commands remain explicitly scoped exceptions.
- Remove bare host invocations and add a mechanical regression test that distinguishes host commands from
  guest payload commands.
- Reconcile the Linux pre-binary floor with the bootstrap path's real use of `curl`, and make the Windows
  GHCup installation path and its prerequisite authority explicit instead of describing an unrealized
  winget-owned flow.
- Align `HostBootstrap.HostPrereqs` with that floor: remove its duplicate Docker reachability, Linux KVM,
  and NVIDIA-runtime gates; the binary-owned `ensure docker` / `ensure incus` / `ensure cuda` transitions
  remain their single authorities.
- Pin and integrity-verify every bootstrap download (including GHCup) before execution; a live
  `get-ghcup`/`ghcup.exe` URL without version and digest provenance is not an accepted toolchain source.
- Preserve deterministic missing-tool diagnostics and add constructors only for tools that production
  code invokes.

#### Validation

- A source scan plus unit tests prove no production host call resolves a bare command through `PATH`.
- Python prerequisite/bootstrap tests cover fresh Ubuntu, Apple, and Windows command sequences, including
  the missing-`curl` and missing-GHCup cases, digest mismatch, and successful verified download; Haskell
  prerequisite tests prove the mirror no longer reasserts Docker/KVM/NVIDIA runtime state.
- `cabal test all --ghc-options=-Werror` from `core/` and the canonical Python check/test gates pass.

#### Remaining Work

None. Closed 2026-07-25: the canonical Python check passed; the Python suite passed with 184 tests; and
`cabal test all --ghc-options=-Werror` passed from `core/` with 377 tests. The demo sources also compiled
with `-Werror`; its independent WebSocket runtime tests remain outside this sprint and currently require
a threaded RTS link.

### Sprint 2.6: Pre-binary C build libraries on Linux [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `tests/test_bootstrap.py`
**Docs to update**: `documents/engineering/prerequisites.md`,
`documents/architecture/python_haskell_boundary.md`

#### Objective

Make the metal frame's toolchain bootstrap install the C build libraries the host-native build links
against, so a pristine Ubuntu 24.04 host can build the project binary.

#### The defect

Discovered 2026-07-29 by the first native Linux CPU lane run on a genuinely pristine guest.
`toolchain_ensure_steps` installs GHCup, GHC, and Cabal, but nothing installs the C libraries GHC itself
links (`gmp`, `ncurses`) or those the project's dependency closure links (`zlib`). On a pristine host the
build therefore died:

```text
Configuring library for zlib-0.7.1.1...
Error: [Cabal-4345]
Missing dependency on a foreign library:
* Missing (or bad) C library: z
```

This is an asymmetry, not merely a missing package. The demo's **in-VM** bootstrap already installs
exactly this set (`build-essential curl libgmp-dev libtinfo-dev libncurses-dev zlib1g-dev pkg-config git
ca-certificates`), so the pristine VM frame worked while the metal frame silently assumed a provisioned
host — precisely the invariant § M states, that the provision → build-the-pb → hand-off shape recurs at
**every** frame including the metal one. It was invisible on every previous lane because each ran on a
developer or CI host that already carried the libraries, and because the Windows and Apple toolchain roots
supply their own C libraries.

Per § L these packages have a supported apt install plan, so the correct behaviour is to **install** them,
not to add them to the fail-fast floor: the floor stays the irreducible pre-binary minimum (OS version,
passwordless sudo, `curl`).

#### Deliverables

- `linux_build_library_probe` — one `dpkg-query -s` over the whole set. It is an all-of probe, so a
  partially provisioned host reinstalls the set instead of being mistaken for a complete one.
- `linux_build_library_install_commands` — `apt-get update` then `apt-get install -y <set>`. The index
  refresh is not optional: a cloud image's index is routinely older than its archive, and installing
  against a stale index 404s on the very packages the step adds.
- `_ensure_linux_build_libraries`, run **before** the GHCup/GHC/Cabal steps, because GHC itself links
  `gmp` and `ncurses`. A satisfied host is a verified no-op that installs nothing.
- An offline build refuses with a message naming the libraries rather than attempting an install.

#### Validation

- Pure argv tests pin the exact probe and both install commands, and assert the set covers the three
  libraries the observed failure implicated.
- Sequence tests prove a pristine Linux host runs probe → update → install → GHCup → GHC → Cabal in that
  order, that a satisfied host runs only the probe, and that Apple's path gains no apt step.
- Offline tests prove the library refusal on Linux, the unchanged build-tool refusal on Apple, and the
  build-tool refusal on a Linux host whose libraries are already present.
- Canonical Python gates: `check_code` (ruff/black/mypy) clean and the suite green at 100% coverage.

#### Remaining Work

Landed and statically validated 2026-07-29: the canonical Python check passed, and the suite passed
**231** tests at **100%** coverage (`fail_under = 100`). The fix was then proved on the real pristine
guest, where `dpkg-query -s zlib1g-dev` was absent before the run and the re-run reported
`Setting up zlib1g-dev:amd64 (1:1.3.dfsg-3.1ubuntu2.1)` and built past `zlib` — the exact package and
step that failed.

Closed 2026-07-29 by the native Linux CPU lane run that consumes it: `hostbootstrap-demo test run all`
reported `10/10`, so the fix carries the whole three-build pristine bootstrap (metal pb, in-VM pb
host-native, project image) and not merely the first build. None remaining.

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
  `Substrate` rows present, adds the `windows-cpu` / `windows-gpu` substrates, and records the
  accelerator host-tool additions as implemented.
