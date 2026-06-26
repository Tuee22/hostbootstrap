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
`installAndVerify` probe-first install-and-verify driver. The reconciler set (`docker`, `colima`,
`lima`, `cuda`, `homebrew`, `ghc`, and the cross-substrate `incus`) carries its applicability
predicates and **install-and-verify** reconcile actions — each exposes a pure, substrate-branched
`installSteps` planner (Homebrew formulae on apple-silicon; `apt-get`/`ghcup`/the NVIDIA container
toolkit on linux), unit-tested without invoking the package manager. They are composed into project
chains as `ensure-*` steps; wrong-host applicability still fails fast before side effects. `ensure incus` is owned by
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md) (see
[development_plan_standards.md § L](development_plan_standards.md)).

This phase is **reopened** for the Windows substrate. The final reconciler set is
`docker` / `colima` / `lima` / `cuda` / `cudawin` / `homebrew` / `ghc` / `incus` / `wsl2` — adding the
Windows CUDA host-build reconciler `ensure cudawin` (this phase, Sprint 3.4) and the Windows WSL2 VM
reconciler `ensure wsl2` (owned by [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)) —
and **retiring** the latent Tart reconciler (Sprint 3.5). The `ensure cudawin` work re-anchors
composition pattern #7 to the **headless host build** (build on the bare Windows host, stage into the
cluster, never run the workload in a build VM); the in-container linux-gpu `ensure cuda`
(`HostBootstrap.Ensure.Cuda`, the nvidia-container-toolkit) stays as a different concern.

## Remaining Work

Two `[Planned]` sprints close the reopened Windows surface and the retirement:

- Sprint 3.4 (`[Planned]`) — the Windows CUDA host-build reconciler `ensure cudawin`, which re-anchors
  composition pattern #7 to the headless host build.
- Sprint 3.5 (`[Planned]`) — retire the latent Tart reconciler (the leftover code surfaces are tracked
  in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).

Both pure paths are cabal-test-closable; the real-Windows-GPU-host CUDA build is Sprint 3.4's remaining
work, and Sprint 3.5 is a pure code-deletion with no real-run gate.

The kube tools (`kubectl`/`helm`/`kind`) are L0 (baked into the base image; the L0 cluster lifecycle
drives them, Phase 5), so they need no separate host reconciler in the in-container path; only
GPU-specific tooling (`nvkind`) is a candidate L1/consumer extra via the extension-stream merge.

## Phase Objective

Implement the substrate-and-ensure-reconciler contract (see
[development_plan_standards.md § L](development_plan_standards.md)). Each host dependency is an
idempotent value carrying a host-applicability predicate and a reconcile action. Projects compose the
concrete reconcilers as `ensure-docker`, `ensure-colima`, `ensure-lima`, `ensure-cuda`,
`ensure-cudawin`, `ensure-homebrew`, `ensure-ghc`, `ensure-wsl2`, and `ensure-incus` chain steps
(`ensure-cudawin` and `ensure-wsl2` are the reopened Windows additions — `ensure-cudawin` owned here,
`ensure-wsl2` by [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)). A reconciler
invoked on a host its predicate rejects fails fast with a one-line diagnostic and a non-zero exit.

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

### Sprint 3.4: Windows CUDA host-build reconciler (CudaWin) [Planned]

**Status**: Planned
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
- Install-and-verify via the substrate-branched `installSteps`: `winget install` the NVIDIA Windows
  driver, the CUDA Toolkit (`Nvidia.CUDA`), and the MSVC C++ build tools
  (`Microsoft.VisualStudio.2022.BuildTools`, nvcc's host compiler). Pure planner, unit-tested without
  invoking winget.

#### Deliverables

- `HostBootstrap.Ensure.CudaWin` templated on the **living** `HostBootstrap.Ensure.Ghc` /
  `HostBootstrap.Ensure.Colima` build-tool reconcilers (probe-first `installAndVerify`, pure
  `installSteps`), wired into `allReconcilers`.
- `HostBootstrap.HostTool` gains the `Winget` (`toolCommandName Winget = "winget"`) and `Nvcc`
  (`toolCommandName Nvcc = "nvcc"`) constructors, resolved to `AbsExe` like every host tool.
- This reconciler is composition pattern #7's first worked instance — a **headless host build**: nvcc
  artifacts are produced on the bare Windows host and **staged into the cluster**, with **no** workload
  run in a build VM (§ N). The in-container linux-gpu `ensure cuda` (`HostBootstrap.Ensure.Cuda`, the
  nvidia-container-toolkit) is unchanged — a different concern that stays.

#### Validation

- `EnsureSpec` asserts `cudawin` applicability (windows-gpu only), the pure winget `installSteps` plan,
  and wrong-host fail-fast on `windows-cpu`; `HostToolSpec` covers the `Winget` / `Nvcc` constructors.
  `cabal build all` and `cabal test` pass.

#### Remaining Work

Real-Windows-GPU-host validation (real-run-gated, § C): the applicability, the pure winget plan, and the
`HostTool` constructors are cabal-test-closable; the live driver — winget installing the driver + CUDA
Toolkit + MSVC and an nvcc artifact built on the bare host and staged into the cluster — is the
remaining closure on a real Windows GPU host.

### Sprint 3.5: Retire Tart reconciler [Planned]

**Status**: Planned
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

None once the deletion lands — this is a pure code-deletion sprint with no real-run gate. The prose
re-anchoring (pattern #7 → headless host build, and the reconciler set dropping the latent build-VM
reconciler) is already done; this sprint removes the leftover code.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` - the reconciler contract, the concrete library values,
  and the fail-fast-on-wrong-host behavior, including `ensure cudawin` and the dropped Tart reconciler.
- `documents/engineering/composition_patterns.md` - pattern #7 re-anchored to the headless host build,
  with `ensure cudawin` as its first worked instance.
- `documents/languages/cuda.md` - the Windows CUDA host-build stack (driver + CUDA Toolkit + MSVC via
  winget) versus the in-container linux-gpu nvidia-container-toolkit.

**Cross-references to add:**
- `system-components.md` keeps the ensure-reconciler table aligned with the implemented library values
  and adds the `ensure cudawin` row and the `Winget` / `Nvcc` host tools.
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces (the Tart code surfaces).
- `development_plan_standards.md` § L carries the final reconciler set and the wrong-host CudaWin
  example.
