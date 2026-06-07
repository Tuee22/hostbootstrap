# Phase 3: Ensure Reconcilers

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-2-host-tools-and-config.md](phase-2-host-tools-and-config.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md)

> **Purpose**: Land each host dependency as an idempotent `ensure` reconciler with a
> host-applicability predicate and a reconcile action, exposed as an optparse subcommand that fails
> fast on the wrong host.

## Phase Status

**Status**: Done

`HostBootstrap.Ensure` provides the `Reconciler` value type, the pure `decide` applicability
function, the fail-fast `runReconciler`, and the generic `ensure <tool>` dispatcher. The six
reconcilers (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, `tart`) are implemented with their
applicability predicates and idempotent reconcile actions, wired into the command tree. Validated
end-to-end: on this `linux-gpu` host `ensure colima` fails fast (exit 1) while `ensure docker` and
`ensure cuda` are idempotent no-ops.

## Phase Objective

Implement the substrate-and-ensure-reconciler contract (see
[development_plan_standards.md § L](development_plan_standards.md)). Each host dependency is an
idempotent value carrying a host-applicability predicate and a reconcile action, exposed as an
optparse subcommand: `ensure docker`, `ensure colima`, `ensure cuda`, `ensure homebrew`,
`ensure ghc`, `ensure tart`. A reconciler invoked on a host its predicate rejects fails fast with a
one-line diagnostic and a non-zero exit.

## Sprints

### Sprint 3.1: Reconciler abstraction + ensure subcommand wiring [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Ensure.hs`
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Ensure` — the `Reconciler` value type (applicability predicate + idempotent
reconcile action) and the generic `ensure <tool>` optparse subcommand dispatcher that fails fast on
the wrong host.

#### Reconciler Contract

- `data Reconciler = Reconciler { applies :: Substrate -> Bool, reconcile :: HostConfig -> IO () }`.
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
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`Colima.hs`, `Cuda.hs`, `Homebrew.hs`, `Ghc.hs`, `Tart.hs`,
`haskell/hostbootstrap-core/src/HostBootstrap/Command.hs`
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

None. The reconcile actions probe state through resolved tools and report/no-op; performing host
mutations (package installs) is exercised on the target substrates during Phase 6 bootstrapping.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` - the reconciler contract, the six subcommands, and
  the fail-fast-on-wrong-host behavior.

**Cross-references to add:**
- `system-components.md` keeps the ensure-reconciler table aligned with the implemented subcommands.
- `legacy-tracking-for-deletion.md` keeps `prereqs.py`'s reconciler-replaced portions on the ledger.
