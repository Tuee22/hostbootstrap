# Phase 3: Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-2-host-tools-and-config.md](phase-2-host-tools-and-config.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md)

> **Purpose**: Land each host dependency as an idempotent `ensure` reconciler with a
> host-applicability predicate and a reconcile action, exposed as library primitives and `ensure-*`
> chain steps that fail fast on the wrong host.

## Phase Status

**Status**: Active

`HostBootstrap.Ensure` provides the `Reconciler` value type, the pure `decide` applicability function,
the fail-fast `runReconciler`, the `runEnsure` library runner, and the shared
`installAndVerify` probe-first install-and-verify driver. The initial (pre-Windows-reopening) reconciler
set (`docker`, `colima`, `lima`, `cuda`, `homebrew`, `ghc`, and the cross-substrate `incus`) carries its applicability
predicates and **install-and-verify** reconcile actions — each exposes a pure, substrate-branched
`installSteps` planner (Homebrew formulae on apple-silicon; `apt-get`/`ghcup`/the NVIDIA container
toolkit on linux, with NVIDIA's signed apt source/keyring bootstrapped before toolkit installation),
unit-tested without invoking the package manager. They are composed into project
chains as `ensure-*` steps; wrong-host applicability still fails fast before side effects. `ensure incus` is owned by
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md) (see
[development_plan_standards.md § L](development_plan_standards.md)).

The Windows reopening is closed. The reconciler set is `docker` / `colima` / `apple-metal` / `cuda` /
`cudawin` / `homebrew` / `ghc` / `lima` / `incus` / `wsl2` — adding the Windows CUDA host-build reconciler
`ensure cudawin` (this phase, Sprint 3.4), the Apple Silicon accelerator build-stack reconciler
`ensure apple-metal` (Sprint 3.6), and the Windows WSL2 VM reconciler `ensure wsl2` (owned by
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)) — and **retiring** the latent Tart
reconciler (Sprint 3.5). The `ensure cudawin` work re-anchors composition pattern #7 to the **headless
host build** (build on the bare Windows host, stage into the cluster, never run the workload in a build
VM); the direct Linux GPU host's `ensure cuda` (`HostBootstrap.Ensure.Cuda`, the NVIDIA container runtime
consumed by the GPU-enabled project container and nvkind) stays a different concern.

**Reopened 2026-07-11 for the `nvkind`-compatible Linux GPU runtime contract.** Phase 5 validation found
that `ensure cuda` registered the Docker `nvidia` runtime but did not converge the two settings required by
the implemented `nvkind` path: the NVIDIA runtime must be the Docker default with CDI enabled, and
`accept-nvidia-visible-devices-as-volume-mounts` must be enabled. Its old satisfaction probe inspected only
the registered-runtime list, so it could falsely return `present (no-op)` while an `nvkind` node could not
receive a GPU. Sprint 3.7 owns the corrected install plan and the official volume-mount smoke probe.

**Reopened 2026-07-09 and closed 2026-07-10 for accelerator build-stack ensure.** The demo accelerator daemon needs host-only
build-stack reconciliation for Apple Silicon and Windows GPU. The implementation landed the same day:
`HostBootstrap.Ensure.AppleMetal` verifies `system_profiler`, `xcrun --sdk macosx --show-sdk-path`, and a
Swift + Metal compile/run probe; `HostBootstrap.Ensure.CudaWin` now verifies CUDA Toolkit, LLVM clang,
Visual Studio Build Tools/VCTools discovery through `vswhere`, the resolved MSVC host compiler, and an
`nvcc -ccbin` CUDA smoke compile. Linux CPU/GPU daemon pods do not run ensure; they trust the hostbootstrap
base image.

## Remaining Work

Open only for Sprint 3.7's real-host gate. The implementation now converges and verifies the exact
NVIDIA-container-toolkit configuration consumed by `nvkind`: Docker's NVIDIA runtime is configured as the
default with CDI enabled, volume-mount device injection is enabled, and the satisfaction probe runs the
same `/dev/null` mount smoke used by the cluster lifecycle. A pristine Debian-family host first receives
NVIDIA's signed stable apt source/keyring (`/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg` and
the signed-by-qualified stable list), so the package install is self-sufficient. `EnsureSpec` covers the
exact plan and probe; the current static gate passes under `-Werror` with all 359 core tests. A Linux
GPU Docker host must still report the reconciler `present (no-op)` before the phase can return to `Done`.
The other reconcilers remain closed.

Real substrate validation now closed for the locally available Apple Silicon lane: on 2026-07-10, an
Apple Silicon M1 Max host built `hostbootstrap-core` with `cabal build all --ghc-options=-Werror` from
`core/`, then invoked `runEnsure HostBootstrap.Ensure.AppleMetal.reconciler`; the reconciler reported
`ensure apple-metal: present (no-op)`, proving the Swift compiler, macOS SDK, visible Metal device, and
Swift/Metal probe are usable.

The Windows GPU real-run gate closed 2026-07-10 on an RTX 3090 host: the reconciler installed the missing
LLVM toolchain, resolved CUDA 13.3 and the Visual Studio VCTools host compiler, compiled the CUDA smoke
artifact through `nvcc -ccbin <MSVC>`, and then reported `ensure cudawin: present (no-op)`. That run also
surfaced and closed Windows portability gaps in `vswhere`-backed MSVC discovery, unattended winget
installation, and the `-Werror` build. The final static gate and governed documentation reconciliation
passed against those fixes.

Previously closed work remains closed. Closed on 2026-06-26 after Phase 2 supplied the Windows Haskell toolchain: `cabal build all` and
`cabal test all` passed from `core/`; `winget install --id Nvidia.CUDA --exact` installed CUDA Toolkit
13.3 on a Windows GPU host; `HostTool.discover Nvcc` resolves
`C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3\bin\nvcc.exe`; and the actual
`ensure cudawin` reconciler reports `present (no-op)`. Tart code surfaces are absent and moved to
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) **Removed Surfaces**.

The kube tools (`kubectl`/`helm`/`kind`) are L0 (baked into the base image; the L0 cluster lifecycle
drives them, Phase 5), so they need no separate host reconciler in the in-container path. The CUDA base also
carries `nvkind`; Phase 5 owns that L0 cluster driver, while this phase owns only the host runtime
reconciliation it consumes.

## Phase Objective

Implement the substrate-and-ensure-reconciler contract (see
[development_plan_standards.md § L](development_plan_standards.md)). Each host dependency is an
idempotent value carrying a host-applicability predicate and a reconcile action. Projects compose the
concrete reconcilers as `ensure-docker`, `ensure-colima`, `ensure-apple-metal`, `ensure-lima`,
`ensure-cuda`, `ensure-cudawin`, `ensure-homebrew`, `ensure-ghc`, `ensure-wsl2`, and `ensure-incus` chain
steps (`ensure-cudawin` and `ensure-wsl2` are the reopened Windows additions — `ensure-cudawin` owned here,
`ensure-wsl2` by [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)). A reconciler invoked
on a host its predicate rejects fails fast with a one-line diagnostic and a non-zero exit.

## Sprints

### Sprint 3.1: Reconciler abstraction + library runner [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Ensure` — the `Reconciler` value type (applicability predicate + idempotent
reconcile action) and the `runEnsure`/`runReconciler` library runners that fail fast on the wrong host.

#### Reconciler Contract

- `data Reconciler = Reconciler { reconcilerName :: String, reconcilerSummary :: String, appliesTo ::
  Substrate -> Bool, requirement :: String, reconcile :: HostConfig -> IO () }` — the host-applicability
  predicate (`appliesTo`) and the idempotent `reconcile` action, plus the stable reconciler name, summary,
  and human-readable applicability used in the wrong-host diagnostic.
- Running an inapplicable reconciler prints a one-line diagnostic and exits non-zero before any
  side effect.
- `reconcile` is idempotent: a second run on a satisfied host is a no-op.

#### Deliverables

- `HostBootstrap.Ensure` with the `Reconciler` type and library runners.
- The fail-fast-on-wrong-host behavior with a non-zero exit and single-line message.

#### Validation

- `EnsureSpec` asserts the applicability predicates and that an inapplicable run exits non-zero
  (`ExitFailure 1`) without performing the action (verified via an `IORef` the action would set).
  `cabal test` passes.

#### Remaining Work

None.

### Sprint 3.2: The concrete reconcilers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`Colima.hs`, `Cuda.hs`, `Homebrew.hs`, `Ghc.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Land the concrete reconcilers as library values.

#### Deliverables

| Reconciler step | Module | Applicable hosts |
|------------|--------|------------------|
| `ensure-docker` | `HostBootstrap.Ensure.Docker` | all substrates |
| `ensure-colima` | `HostBootstrap.Ensure.Colima` | `apple-silicon` |
| `ensure-cuda` | `HostBootstrap.Ensure.Cuda` | `linux-gpu` |
| `ensure-homebrew` | `HostBootstrap.Ensure.Homebrew` | `apple-silicon` |
| `ensure-ghc` | `HostBootstrap.Ensure.Ghc` | `apple-silicon` |

- Each reconciler resolves its tools through `HostBootstrap.HostTool` (no `$PATH` bare names).
- Each carries the correct applicability predicate from the table above.

#### Validation

- `EnsureSpec` verifies idempotent/right-host action behavior and wrong-host fail-fast behavior without
  requiring a top-level `ensure` command.
- `cabal build all` succeeds.

#### Remaining Work

None.

### Sprint 3.3: Install-and-verify reconcile actions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs` (`InstallStep`,
`installAndVerify`), `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`, `Colima.hs`,
`Cuda.hs`, `Homebrew.hs`, `Ghc.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Give each reconcile action a real, substrate-branched **install** so it brings the host to the desired
state when the dependency is absent and is a verified no-op when it is present (install-and-verify, not
check-only; see [development_plan_standards.md § L](development_plan_standards.md)).

#### Reconciler Contract

- `HostBootstrap.Ensure` exposes `InstallStep` (a resolved `HostTool` plus arguments) and
  `installAndVerify name probe plan` — the probe-first loop: no-op when satisfied; otherwise run the
  plan re-resolving tools after each step; re-verify and fail fast if still missing.
- Each reconciler exposes a pure `installSteps :: Substrate -> Either String [InstallStep]` planner
  (Homebrew on apple-silicon; `apt-get`/`ghcup`/the NVIDIA container toolkit on linux), so the plan is
  unit-tested without invoking the package manager. The live IO driver is exercised in real bootstrap
  runs.

#### Deliverables

- The phase-3 reconcile actions route through `installAndVerify` with their probe and pure
  `installSteps` planner; `homebrew` (toolchain root) and Apple `docker` (deferred to `ensure colima`)
  return `Left` with a fail-fast instruction by design. Linux `ensure docker` also reconciles invoking
  user membership in the `docker` group, applies an immediate socket ACL when needed, and verifies
  future-session socket access.

#### Validation

- `EnsureSpec` "install plans" asserts the planned steps for every reconciler across substrates
  (Homebrew formulae on apple; apt/ghcup/container-toolkit on linux; `Left` for `homebrew` and Apple
  `docker`). `cabal build all` and `cabal test` pass.

#### Remaining Work

None.

### Sprint 3.4: Windows CUDA host-build reconciler (CudaWin) [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/CudaWin.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs` (the `Winget` / `Nvcc` constructors),
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/composition_patterns.md`, `documents/languages/cuda.md`, `system-components.md`

#### Objective

Land `ensure cudawin`, the Windows CUDA **host-build** reconciler, and re-anchor composition pattern #7
to the headless host build it instantiates.

#### Reconciler Contract

- `ensure cudawin` `appliesTo = isWindowsGpu` (windows-gpu only); the probe is `nvcc -V` resolving and
  the NVIDIA driver reporting a GPU on the Windows host. A run on `windows-cpu` (or any non-Windows-GPU
  host) fails fast with the one-line wrong-host diagnostic — an applicability misuse, never an absent
  dependency (§ L).
- NVIDIA device/driver visibility is part of detecting the `windows-gpu` substrate; a host without a
  working `nvidia-smi` is not classified as `windows-gpu`. Once that substrate exists, install-and-verify
  uses the pure `installSteps` planner to run unattended `winget install` steps for the CUDA Toolkit
  (`Nvidia.CUDA`), MSVC C++ Build Tools/VCTools (`Microsoft.VisualStudio.2022.BuildTools`, nvcc's host
  compiler), and LLVM clang (`LLVM.LLVM`).

#### Deliverables

- `HostBootstrap.Ensure.CudaWin` templated on the **living** `HostBootstrap.Ensure.Ghc` /
  `HostBootstrap.Ensure.Colima` build-tool reconcilers (probe-first `installAndVerify`, pure
  `installSteps`), wired into `allReconcilers`.
- `HostBootstrap.HostTool` gains the `Winget` (`toolCommandName Winget = "winget"`) and `Nvcc`
  (`toolCommandName Nvcc = "nvcc"`) constructors, resolved to `AbsExe` like every host tool.
- This reconciler is composition pattern #7's first worked instance — a **headless host build**: nvcc
  artifacts are produced on the bare Windows host, with **no** workload run in a build VM (§ N). Staging
  those artifacts into a concrete cluster is chain/consumer lifecycle work after the host-build toolchain
  is present; it is not a Phase-3 reconciler prerequisite. The direct Linux GPU host's `ensure cuda`
  (`HostBootstrap.Ensure.Cuda`, the NVIDIA container runtime) is a different concern that stays.

#### Validation

- `EnsureSpec` asserts `cudawin` applicability (windows-gpu only), the pure winget `installSteps` plan,
  and wrong-host fail-fast on `windows-cpu`; `HostToolSpec` covers the `Winget` / `Nvcc` constructors.
  `cabal build all` and `cabal test all` pass.

#### Remaining Work

None. On 2026-06-26, `cabal build all` and `cabal test all` passed; `winget install --id Nvidia.CUDA
--exact` installed CUDA Toolkit 13.3; `HostTool.discover Nvcc` resolved the installed `nvcc.exe`; and
`runEnsure HostBootstrap.Ensure.CudaWin.reconciler` reported `ensure cudawin: present (no-op)` on the
Windows GPU host.

### Sprint 3.5: Retire Tart reconciler [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Tart.hs` (deleted),
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/EnsureSpec.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/composition_patterns.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Delete the latent Tart reconciler now that Windows is the third metal substrate and the headless host
build (Sprint 3.4) has replaced Tart's build-VM shape. Tart was core-only and latent — registered in
`allReconcilers` but absent from every demo chain — and the siblings infernix and jitML already bypassed
it for a headless host bridge.

#### Deliverables

Delete the Tart code surfaces (tracked in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)):

- `HostBootstrap.Ensure.Tart` (`core/hostbootstrap-core/src/HostBootstrap/Ensure/Tart.hs`);
- the `Tart` import and the `allReconcilers` entry in `Command.hs` (`Command.hs:62` / `Command.hs:86`);
- the `Tart` constructor and `toolCommandName Tart = "tart"` in `HostTool.hs`
  (`HostTool.hs:37` / `HostTool.hs:61`);
- the exposed-module line in `hostbootstrap-core.cabal` (`hostbootstrap-core.cabal:38`);
- the import, reconciler-name, `appliesTo`, and `installSteps` cases in `test/EnsureSpec.hs`;
- the entry in `test/HostToolSpec.hs`.

After deletion the reconciler set is `docker` / `colima` / `lima` / `cuda` / `cudawin` / `homebrew` /
`ghc` / `incus` / `wsl2`, with no Tart surface anywhere in the tree.

#### Validation

- `cabal build all` and `cabal test` pass with `HostBootstrap.Ensure.Tart` gone and no `Tart`
  constructor; `EnsureSpec` / `HostToolSpec` no longer reference it; `allReconcilers` no longer lists it.
  The two Pending entries in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) move to **Removed Surfaces** in the
  same change.

#### Remaining Work

None. `cabal build all` and `cabal test all` passed on 2026-06-26 with no Tart module, constructor,
reconciler entry, exposed module, or tests. The Tart entries are now in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) **Removed Surfaces**.

### Sprint 3.6: Accelerator build-stack reconcilers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/AppleMetal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/CudaWin.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/engineering/ensure_reconcilers.md`, `documents/languages/cuda.md`, `system-components.md`

#### Objective

Ensure host-resident accelerator build stacks only where host remediation is appropriate: Apple Silicon
Swift/Metal and Windows GPU CUDA.

#### Deliverables

- New `ensure-apple-metal` reconciler (`appliesTo = isAppleSilicon`) with probe-first install-and-verify
  semantics around a real Swift + Metal compile/run probe.
- Hardened `ensure-cudawin` (`appliesTo = isWindowsGpu`) with CUDA Toolkit, MSVC C++ workload, LLVM clang,
  and a CUDA smoke compile.
- Clear wrong-host diagnostics for Apple Metal ensure on non-Apple substrates and CudaWin on non-Windows-GPU
  substrates.
- No runtime package-manager remediation in Linux daemon pods.

#### Validation

- `EnsureSpec` covers applicability, wrong-host fail-fast, and pure install plans.
- `EnsureSpec` covers the Apple Metal SDK/probe builders and the CudaWin clang/vswhere/nvcc smoke builders.
- `cabal build all --ghc-options=-Werror` and `cabal test all` passed from `core/` on Windows GPU on
  2026-07-10; that phase-close snapshot reported 331 tests. The 2026-07-11 cumulative snapshot reported
  345 tests; the current 2026-07-12 static gate reports 359 tests.
- Real integration gates prove `ensure-apple-metal` builds the Swift/Metal worker on Apple Silicon and the
  hardened `ensure-cudawin` builds the CUDA worker on Windows GPU. The Apple Silicon gate closed
  2026-07-10 on an M1 Max host (`ensure apple-metal: present (no-op)`). The Windows GPU gate closed the
  same day on an RTX 3090 host after the reconciler resolved CUDA 13.3, LLVM, and the VCTools host compiler
  through `vswhere`, compiled the `nvcc -ccbin` smoke artifact, and reported `ensure cudawin: present
  (no-op)`.

#### Remaining Work

None.

### Sprint 3.7: `nvkind`-compatible Linux GPU runtime reconciliation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/accelerator_daemon.md`, `documents/languages/cuda.md`, `system-components.md`

#### Objective

Make `ensure cuda` converge to the exact Docker/NVIDIA-container-toolkit configuration the Phase 5
`nvkind` cluster path consumes, and make its no-op probe prove that configuration rather than only seeing
an installed runtime name.

#### Deliverables

- Bootstrap NVIDIA's signed stable Debian repository/keyring before installing the toolkit package on a
  pristine supported Ubuntu host: dearmor the key into
  `/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg` and write the stable apt list with that exact
  `signed-by` qualifier.
- Configure the Docker NVIDIA runtime with `--set-as-default --cdi.enabled`.
- Enable `accept-nvidia-visible-devices-as-volume-mounts=true` in the NVIDIA container-toolkit config.
- Restart Docker after both idempotent configuration writes.
- Use the `nvkind` volume-mount smoke (`/dev/null` mounted at
  `/var/run/nvidia-container-devices/all`, then `nvidia-smi -L`) as the satisfaction probe.

#### Validation

- `EnsureSpec` covers the exact install steps and volume-mount smoke arguments/classifier. **Passed
  2026-07-11.**
- `cabal build all --ghc-options=-Werror` and `cabal test all --ghc-options=-Werror` pass from `core/`.
  **Passed 2026-07-11: 345 tests; current 2026-07-12 cumulative gate: 359 tests.**
- A Linux GPU host reports the reconciler `present (no-op)` after the smoke sees a GPU.

#### Remaining Work

Run the verified no-op gate on a Linux GPU Docker host. No implementation or static-test work remains.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` - the reconciler contract, the concrete library values,
  and the fail-fast-on-wrong-host behavior, including `ensure cudawin` and the dropped Tart reconciler.
- `documents/engineering/composition_patterns.md` - pattern #7 re-anchored to the headless host build,
  with `ensure cudawin` as its first worked instance.
- `documents/languages/cuda.md` - the Windows CUDA host-build stack (driver + CUDA Toolkit + MSVC via
  winget) versus the direct Linux GPU host's NVIDIA container runtime and in-cluster CUDA worker.

**Cross-references to add:**
- `system-components.md` keeps the ensure-reconciler table aligned with the implemented library values
  and adds the `ensure cudawin` row and the `Winget` / `Nvcc` host tools.
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces (the Tart code surfaces).
- `development_plan_standards.md` § L carries the final reconciler set and the wrong-host CudaWin
  example.
