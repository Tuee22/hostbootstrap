# Phase 3: Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-2-host-tools-and-config.md](phase-2-host-tools-and-config.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md)

> **Purpose**: Land each host dependency as an idempotent `ensure` reconciler with a
> host-applicability predicate and a reconcile action, exposed as an optparse subcommand that fails
> fast on the wrong host.

## Phase Status

**Status**: Done

`HostBootstrap.Ensure` provides the `Reconciler` value type, the pure `decide` applicability function,
the fail-fast `runReconciler`, the generic `ensure <tool>` dispatcher, and the shared
`installAndVerify` probe-first install-and-verify driver. The reconciler set (`docker`, `colima`,
`lima`, `cuda`, `homebrew`, `ghc`, `tart`, and the cross-substrate `incus`) carries its applicability
predicates and **install-and-verify** reconcile actions — each exposes a pure, substrate-branched
`installSteps` planner (Homebrew formulae on apple-silicon; `apt-get`/`ghcup`/the NVIDIA container
toolkit on linux), unit-tested without invoking the package manager. They are wired into the command
tree (on this `linux-gpu` host `ensure colima` fails fast while `ensure docker`/`ensure cuda`/`ensure
incus` install-and-verify). `ensure incus` is owned by
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md). This phase is `Done` (see
[development_plan_standards.md § L](development_plan_standards.md)).

The kube tools (`kubectl`/`helm`/`kind`) are L0 (baked into the base image; the L0 cluster lifecycle
drives them, Phase 5), so they need no separate host reconciler in the in-container path; only
GPU-specific tooling (`nvkind`) is a candidate L1/consumer extra via the extension-stream merge.

## Phase Objective

Implement the substrate-and-ensure-reconciler contract (see
[development_plan_standards.md § L](development_plan_standards.md)). Each host dependency is an
idempotent value carrying a host-applicability predicate and a reconcile action, exposed as an
optparse subcommand: `ensure docker`, `ensure colima`, `ensure lima`, `ensure cuda`, `ensure homebrew`,
`ensure ghc`, `ensure tart`, and `ensure incus`. A reconciler
invoked on a host its predicate rejects fails fast with a one-line diagnostic and a non-zero exit.

## Sprints

### Sprint 3.1: Reconciler abstraction + ensure subcommand wiring [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Ensure` — the `Reconciler` value type (applicability predicate + idempotent
reconcile action) and the generic `ensure <tool>` optparse subcommand dispatcher that fails fast on
the wrong host.

#### Reconciler Contract

- `data Reconciler = Reconciler { reconcilerName :: String, reconcilerSummary :: String, appliesTo ::
  Substrate -> Bool, requirement :: String, reconcile :: HostConfig -> IO () }` — the host-applicability
  predicate (`appliesTo`) and the idempotent `reconcile` action, plus the subcommand name, the optparse
  summary, and the human-readable applicability used in the wrong-host diagnostic.
- Running an inapplicable reconciler prints a one-line diagnostic and exits non-zero before any
  side effect.
- `reconcile` is idempotent: a second run on a satisfied host is a no-op.

#### Deliverables

- `HostBootstrap.Ensure` with the `Reconciler` type and the `ensure` command group.
- The fail-fast-on-wrong-host behavior with a non-zero exit and single-line message.

#### Validation

- `EnsureSpec` asserts the applicability predicates and that an inapplicable run exits non-zero
  (`ExitFailure 1`) without performing the action (verified via an `IORef` the action would set).
  `cabal test` passes.

#### Remaining Work

None.

### Sprint 3.2: The six reconcilers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`Colima.hs`, `Cuda.hs`, `Homebrew.hs`, `Ghc.hs`, `Tart.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Land the six concrete reconcilers as `ensure` subcommands.

#### Deliverables

| Subcommand | Module | Applicable hosts |
|------------|--------|------------------|
| `ensure docker` | `HostBootstrap.Ensure.Docker` | all substrates |
| `ensure colima` | `HostBootstrap.Ensure.Colima` | `apple-silicon` |
| `ensure cuda` | `HostBootstrap.Ensure.Cuda` | `linux-gpu` |
| `ensure homebrew` | `HostBootstrap.Ensure.Homebrew` | `apple-silicon` |
| `ensure ghc` | `HostBootstrap.Ensure.Ghc` | `apple-silicon` |
| `ensure tart` | `HostBootstrap.Ensure.Tart` | `apple-silicon` (build-only) |

- Each reconciler resolves its tools through `HostBootstrap.HostTool` (no `$PATH` bare names).
- Each carries the correct applicability predicate from the table above.

#### Validation

- `hostbootstrap ensure <tool>` is idempotent on a satisfied host and fails fast on the wrong host
  (verified on the development `linux-gpu` host: `ensure docker`/`ensure cuda` no-op, `ensure colima`
  exits 1).
- `cabal build all` succeeds.

#### Remaining Work

None.

### Sprint 3.3: Install-and-verify reconcile actions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs` (`InstallStep`,
`installAndVerify`), `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`, `Colima.hs`,
`Cuda.hs`, `Homebrew.hs`, `Ghc.hs`, `Tart.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`
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

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` - the reconciler contract, the concrete subcommands, and
  the fail-fast-on-wrong-host behavior.

**Cross-references to add:**
- `system-components.md` keeps the ensure-reconciler table aligned with the implemented subcommands.
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces.
