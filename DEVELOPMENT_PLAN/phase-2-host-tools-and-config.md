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

**Reopened 2026-08-03 for the host-invocation *shape* boundary (Sprint 2.7).** This phase's closure rested
on Sprint 2.5's criterion — *"a source scan plus unit tests prove no production host call resolves a bare
command through `PATH`"* — which is a scan over **which executable** an invocation names. Nothing in this
phase ever covered **in what shape** a process is invoked, and the Apple Silicon lane found the hole: the
host-resident accelerator daemon was launched from a `System.Process.CreateProcess` record assembled at
its call site, with `std_in`/`std_out`/`std_err` set to `NoStream`. On POSIX that *closes* the child's
descriptors, which the `process` documentation permits only for a child that never uses them. This child
uses standard output in its first statement, and a threaded-RTS child then claims the freed descriptors
for its own IO-manager control channel; it wedged or exited before reaching substrate detection, and none
of its ten failure paths could report why. A green test
(`demo/test/CommandsSpec.hs`) asserted that disposition, so every gate agreed with the defect.

The generalized contract is [§ HH](development_plan_standards.md), whose canonical architecture is
[unrepresentable_state](../documents/architecture/unrepresentable_state.md): § K fixes which path is
invoked, § HH fixes the shape every such value may take. **Sprint 2.7 closed that boundary on
2026-08-03**, static gate and Apple Silicon real-run gate together, and the phase closed with it.

**This reopening adds work; it reverses none.** Sprints 2.1–2.6 hold independently — the closed `HostTool`
enumeration, `AbsExe` opacity and its smart constructor, the substrate classification core, the pre-binary
Python floor, and the C build-library bootstrap are all unaffected, and the bare-command source scan
remains correct about the axis it covers. Obsolete surfaces are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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

**None. Sprint 2.7 closed 2026-08-03 and with it the phase.** Resolution and shape are two axes, and this
phase had only ever closed the first. `HostBootstrap.Detached` now seals the launch of a child that
outlives its launcher: the caller-assembled `CreateProcess` and its `NoStream` disposition are deleted,
the static gate passed at **901/901** in `core/` and **112/112** in the demo workspace under `-Werror`,
the demo's `fourmolu`/`hlint` halves passed in the published base image, and the § C real-run gate — the
Apple Silicon `hostbootstrap-demo test run all` lane, the only lane that exercises this boundary —
reported **`10/10 passed`**. The host daemon reached readiness on all four bring-ups and `e2e-tabs`
passed on both variants, so the path behind readiness is proved live rather than merely started.

The remaining work below is closed and retained as historical scope.

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

### Sprint 2.7: Close the host-invocation shape boundary [Done]

**Status**: Done
**Blocked by**: None
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Detached.hs`,
`core/hostbootstrap-core/test/DetachedSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeDetachedLaunch.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/CommandsSpec.hs`
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/readiness.md`,
`documents/engineering/accelerator_daemon.md`, `documents/operations/demo_runbook.md`,
`system-components.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make the invocation *shape* of a child that outlives its launcher a property of a closed boundary rather
than fields a call site fills in (§ HH), so the disposition that wedged the Apple Silicon host daemon is
not expressible.

#### Deliverables

- One sealed launch boundary in core. Its record constructor and field accessors are private, so no
  module outside it assembles a `System.Process.CreateProcess` for a detached child. The executable is an
  `AbsExe` (§ K) and the working directory is absolute by construction.
- Every field with exactly one lawful value for such a child is fixed inside that boundary and is not a
  parameter: the stdio disposition, descriptor inheritance, session, complete environment, and working
  directory. Each of `StdStream`'s other constructors is wrong for its own reason — `Inherit` retains the
  launcher's capture pipe so nothing reading the launcher observes EOF, `CreatePipe` blocks the parent on
  an EOF that never arrives or delivers `SIGPIPE` after it closes the read end, and `NoStream` closes the
  descriptor.
- A rank-2 bracket owning the *launch*, never the child's lifetime: on exit the child is still running and
  only the launcher's own handles are released. Acquire-and-spawn is total — it either succeeds or returns
  a typed failure having created no child — while the body's exceptions propagate unchanged, so the
  existing ownership-preserving abort paths keep their behaviour.
- The child's own output is retained for the launcher to quote, so a startup failure names its cause
  (§ CC) instead of collapsing to "the process is gone".
- `hostAcceleratorDaemonProcess` and its `NoStream` disposition are deleted, and the demo's daemon launch
  consumes the boundary. The daemon's argv is written once and read by both the launch and the process
  identity matcher, which currently re-spells it four ways.

#### Validation

- Two compile-fail fixtures prove the seals, registered in `CompileFailSpec` with expected diagnostics so
  each must fail for its named reason rather than incidentally (§ HH). `ForgeDetachedLaunch.hs` proves the
  launch record, its running-child value, the working directory, and the output sink are not
  caller-constructible and that the assembled process specification is unreachable;
  `RelabelDetachedLaunch.hs` proves the launch cannot be re-pointed by record update. They are separate
  because a not-in-scope record field aborts GHC's renamer and would suppress the other four diagnostics.
- The `CompileFailSpec` matcher normalises GHC's typographic-vs-ASCII identifier quoting alongside its
  line wrapping. Neither axis says whether a fixture was rejected for the intended reason, and
  normalising both is what lets an expectation stay **one contiguous phrase including the identifier it
  names** — the shape [unrepresentable_state](../documents/architecture/unrepresentable_state.md)
  requires, because a phrase split into separately-matched tokens can be satisfied by an unrelated
  in-scope error on the same line. `ForgeStepExecution.hs`'s three-token expectation, the one instance of
  that pattern, is rewritten to two contiguous phrases.
- A **behavioural** spec (`DetachedSpec`) launches a real child through the boundary — the core test
  executable re-invoked through a probe argv, the same separate-process idiom the protected-entry and
  harness-reservation probes use — and observes that it read its standard input to EOF, that both output
  streams reached the retained sink, and that it kept writing after the bracket returned. This replaces
  the assertion that pinned the defect: no unlawful disposition passes it, so it fails when the boundary
  is missing instead of certifying its absence. `NoStream` closes the descriptor so the read raises,
  `Inherit` sends the output to the test runner rather than the sink, and `CreatePipe` does not typecheck
  because the disposition is not a parameter. The same spec proves acquire-and-spawn is total on a
  missing executable and an unusable sink, and that a body exception propagates unchanged.
- A source-drift check proves no production module outside the sealed boundary names the
  descriptor-closing stdio disposition, scanning `core/hostbootstrap-core/src`,
  `core/hostbootstrap-core/app`, `demo/src`, and `demo/app`.
- `cabal build all --enable-tests --ghc-options=-Werror` and `cabal test all --ghc-options=-Werror` pass
  from `core/`; the demo workspace passes under the same gate with `fourmolu --mode check app src` and
  `hlint app src` clean; the canonical Python gates pass.
- **Real-run gated (§ C).** The Apple Silicon `hostbootstrap-demo test run all` lane exercises this
  boundary and is the only lane that does — Windows GPU uses a separate hidden-launch path and in-cluster
  daemons inherit the kubelet's streams. Sprint 2.7 does not close on the static gate alone. Passing the
  static gate is expected to expose the *next* Apple-lane defect rather than turn the lane green; that
  residue belongs to the lane's owners in Sprints 13.17 / 15.8 / 16.5 / 18.5.

#### Remaining Work

**The implementation and its static gate landed 2026-08-03.** `HostBootstrap.Detached` is the sealed
boundary: `DetachedLaunch` exports neither its record constructor nor any field accessor, the assembled
`CreateProcess` is private, and the stdio disposition, `close_fds`, POSIX session, and Windows console
detachment are fixed inside it. The lawful disposition is `UseHandle` throughout — standard input is the
host's null device, so the child sees an open descriptor already at EOF, and both output streams share
one retained sink. `withDetachedChild` is a rank-2 bracket over the *launch*: acquire-and-spawn returns a
typed `DetachedLaunchError` having created no child, the body's exceptions propagate unchanged, and on
exit the child is still running with only the launcher's handles released.

`hostAcceleratorDaemonProcess` and its `NoStream` disposition are deleted. The demo now supplies operands
only — the daemon `AbsExe`, the single `hostAcceleratorDaemonArgs` argv that both the launch and the
process-identity matcher's four host-reported spellings are derived from, the complete child environment,
an absolute working directory, and the absolute sink at
`.build/accelerator-daemon/hostbootstrap-demo.accelerator.output`. That sink is a lifecycle witness like
the pid, ready, and shutdown files and is removed with them, and a daemon that fails to reach readiness
now has its own output quoted under the failure (§ CC) instead of collapsing to "the process is gone".

Static evidence, 2026-08-03 on Apple Silicon: `cabal test all --ghc-options=-Werror` from `core/` passed
**901/901**, and the demo workspace built and tested clean under `-Werror` at **112/112**. The demo's
formatter and linter halves were run in the published base image
(`docker run … basecontainer-cpu-arm64 fourmolu --mode check app src` and `… hlint app src`), both clean,
and were then re-run four times inside the lane below by the in-Dockerfile `check-code` stage.

**Real-run gate MET (§ C) 2026-08-03 — the Apple Silicon lane reports `10/10 passed`.** This is the
closing gate this sprint reserved, and it is also the first green Apple Silicon lane recorded anywhere in
this plan. Host: Apple M1 Max, 64 GiB, macOS 25.5.0 arm64, Lima/VZ, GHC 9.12.4.
`hostbootstrap-demo test run all` passed all five cases (`pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, `durable-readback`) on both config variants (`hello-world`, `hello-universe`).

The boundary is what changed. The step that reported `accelerator-daemon: pid 41211 exited before
readiness` on 2026-08-02/03 instead reported `accelerator-daemon: host daemon ready at
ws://127.0.0.1:30081/api/accelerator/daemon` on **all four** bring-ups — two variants, each brought up
once for its cases and again by `durable-readback`'s destroy → up cycle. `e2e-tabs` then passed on both
variants, which is the stronger result: that case only passes when a connected daemon actually serves
`/api/accelerator/add`, so the whole host-resident path behind readiness — Apple Metal ensure, the
Swift/Metal worker build, the WebSocket connect, and the CBOR round trip — is proved live, not merely
started. The in-Dockerfile `check-code` gate (`fourmolu`, `hlint`, `cabal --ghc-options=-Werror`) passed
on each of the four image builds.

Teardown was clean on every cycle: no Lima instance, generated config, or `.test_data/<runId>` remained,
and `demo/.data/web/marker` survived `durable-readback`'s destroy → up on both variants, so the
never-delete-`.data` invariant held across the lane.

The prediction in the § C bullet above — that passing the static gate would expose the *next* Apple-lane
defect rather than turn the lane green — was wrong, and is left standing above as the expectation of
record. The launch shape was the only defect on this lane. The evidence for the original defect is
recorded once with [phase-13 Sprint 13.17](phase-13-hostbootstrap-demo.md).

None remaining.

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
