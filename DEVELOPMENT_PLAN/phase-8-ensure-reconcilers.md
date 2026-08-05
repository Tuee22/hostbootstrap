# Phase 8 — Ensure reconcilers

**Status**: Done
**Depends on**: Phase 7 (Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus a live `ensure` sweep on linux-cpu

> **Purpose**: Bring each host dependency to a declared state idempotently, with substrate applicability
> decided by the classified substrate rather than attempted and caught.

## Phase Objective

Once the binary exists it can install what it needs. Each `ensure` reconciler answers one question — is this
dependency present at the required version, and if not, install it — and answers it idempotently, so a second
run is a no-op rather than a reinstall. Applicability is derived from the classified substrate, so a
reconciler that cannot apply reports that rather than failing.

The accelerator reconcilers for non-baseline substrates are written here; their live confirmation belongs to
the substrate phases (§ II), because a run on one substrate proves nothing about another.

## Sprints

### Sprint 8.1: The reconciler contract [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

One shape every reconciler has.

#### Deliverables

- A reconciler is a total function from the classified substrate and typed host config to one of: already
  present (no-op), installed, or not applicable on this substrate.
- Idempotence is a property of the contract, not of each implementation's care: a reconciler observes before
  it acts, and the observation is what decides.
- Every external call resolves through the closed `HostTool` boundary; no reconciler invokes a bare name.
- A reconciler reports its outcome structurally, so `ensure` can print a report card rather than a log.

#### Validation

`EnsureSpec` covers the three outcomes per reconciler and the second-run no-op.

#### Remaining Work

None.

### Sprint 8.2: The baseline reconcilers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Ghc.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Homebrew.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `documents/engineering/incus.md`

#### Objective

Cover the dependencies the baseline lane needs.

#### Deliverables

- `ensure docker`, `ensure ghc`, and `ensure incus` bring the container runtime, the pinned toolchain, and the
  Linux host provider to their declared states.
- `ensure homebrew` and `ensure colima` cover the macOS package and provider path.
- The Colima reconciler applies the project's declared resource budget rather than a default profile, so a
  provider is sized by the project.

#### Validation

`EnsureSpec` and `ColimaSpec` cover each reconciler's branches. Live `ensure` on linux-cpu reports the
install-then-no-op pair.

#### Remaining Work

None.

### Sprint 8.3: Accelerator and provider reconcilers for non-baseline substrates [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/AppleMetal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/CudaWin.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Lima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`,
`documents/engineering/accelerator_daemon.md`

#### Objective

Write each non-baseline reconciler here; confirm it on its own substrate later.

#### Deliverables

- `ensure apple-metal` reconciles the Swift/Metal toolchain; `ensure cuda` and `ensure cudawin` reconcile the
  CUDA toolchains for Linux and Windows.
- `ensure lima` and `ensure wsl2` reconcile the Apple and Windows host providers.
- Each declares its applicable substrates, so invoking it on a substrate it does not apply to is a reported
  `not applicable` rather than an attempted install.
- The accelerator matrix is one table: Swift/Metal on apple-silicon, `nvcc` on linux-gpu and windows-gpu, and
  `clang++` on linux-cpu.

#### Validation

`EnsureSpec` covers each reconciler's applicability decision and both branches of its observation on the
substrates the static suite can model. Live confirmation on apple-silicon, nvidia, and windows is listed by
the corresponding substrate phase.

#### Remaining Work

None. Live confirmation is not a closure obligation of this phase (§ C, § II).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — where reconcilers sit between the host floor and the plan.

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` — the reconciler contract and the applicability rule.
- `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/engineering/wsl2.md` — the
  provider reconcilers.
- `documents/engineering/accelerator_daemon.md` — the per-substrate accelerator toolchain matrix.

**Cross-references to add:**
- `development_plan_standards.md` § L names this phase as the owner of the reconciler contract.
