# Phase 8 — Ensure reconcilers

**Status**: Done
**Depends on**: Phase 7 (Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Bring each host dependency to a declared state idempotently, with substrate applicability
> decided by the classified substrate rather than attempted and caught, and supply the generic resolved-tool
> self-reference Lift that crosses already-described frame contexts.

## Phase Objective

Once the binary exists it can install what it needs. Each `ensure` reconciler answers one question — is this
dependency present at the required version, and if not, install it — and answers it idempotently, so a second
run is a no-op rather than a reinstall. Applicability is derived from the classified substrate, so a
reconciler that cannot apply reports that rather than failing.

The accelerator reconcilers for non-baseline substrates are written here; their live confirmation belongs to
the substrate phases (§ II), because a run on one substrate proves nothing about another.

Above Phase 7's pure target/context vocabulary, this phase resolves the one outer host tool and folds a
self-reference command through any nested stack. Provider lifecycle realization and registry-aware leaf
extensions remain later additive consumers.

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

- A reconciler is a host-applicability predicate plus a `HostConfig -> IO ()` reconcile action. The pure
  `decide` function returns either the exact wrong-host diagnostic or the action to run; it does not mint a
  typed reconcile result.
- Reconcile actions are probe-first. A satisfied probe takes the successful no-op path; an absent dependency
  with a supported plan is installed and re-probed; an unsupported or still-unsatisfied state fails closed.
- Every external call resolves through the closed `HostTool` boundary; no reconciler invokes a bare name.
- `runReconciler` emits the one-line wrong-host diagnostic to `stderr` and exits nonzero before calling the
  action. Successful actions currently report through ordinary `IO ()`; typed retained outcomes belong to the
  later plan-owned reconcile boundary.

#### Validation

`EnsureSpec` covers pure applicability/diagnostic selection and the applicable action path. Deterministic
install/re-probe/no-op coverage is owned by Sprint 8.2.

#### Remaining Work

None.

### Sprint 8.2: The baseline reconcilers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Ghc.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Homebrew.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `documents/engineering/incus.md`

#### Objective

Cover the dependencies the baseline lane needs.

#### Deliverables

- `ensure docker`, `ensure ghc`, and `ensure incus` bring the container runtime, the pinned toolchain, and the
  Linux host provider to their declared states.
- `ensure homebrew` covers the macOS package prerequisite without selecting or mutating a project provider
  profile.
- Every member remains config-free. A provider adapter that needs validated project, plan, budget, partition,
  reservation, or profile evidence is not a `Reconciler` and cannot appear in this phase's registry.

#### Validation

`EnsureSpec` covers each reconciler's pure plan and applicability branches. A deterministic seam around the
production `installAndVerify` driver covers already-present no-op, absent → install → successful re-probe,
second-run no-op, install refusal, install failure, and failed re-probe without invoking a real package
manager. The focused `EnsureSpec`/`LiftSpec`/`CordonSpec` gate passed 128/128 with `-Werror` on 2026-08-09
(aarch64-osx, GHC 9.12.4). The [worked-demo phase](phase-24-worked-demo.md)
exercises the baseline reconcilers in the live lifecycle; that later integration evidence is not a closure
obligation of this static phase.

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

### Sprint 8.4: Generic resolved-tool self-reference Lift [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/composition_methodology.md`,
`documents/architecture/build_and_run_model.md`

#### Objective

Fold one self-reference command through the pure context stack while resolving only the outer host tool and
keeping provider realization and registry policy above the generic dispatcher.

#### Deliverables

- `HostBootstrap.Lift` publicly reexports `HostBootstrap.Lift.Context` and owns `SelfRef`, `LiftDispatch`,
  `LiftLeaf`, `foldLeaf`, `foldLift`, and the effectful self-subcommand entrypoints.
- The fold preserves outermost-first nesting, streams child config over `stdin`, lowers container delivery,
  and resolves only the outer host command through `HostConfig`/`HostTool`; target-internal tools remain the
  nested machine's own commands.
- `shellQuoteArgs` is the single generic quoting implementation available to later additive leaf helpers.
- `Ensure.Wsl2` owns its prerequisite diagnostics, output normalization, virtualization classification, and
  `bcdedit` argument rendering without importing the later WSL2 provider realization.
- Generic Lift imports no Incus, Lima, WSL2, `Substrate.Provider`, Registry, or cluster realization module.
- Reachability, blob-upload, and registry-auth leaf helpers are not part of this sprint; the
  composition-and-network phase adds them over this lower fold.

#### Validation

`LiftSpec` covers local, Incus, Lima, WSL2, container, and nested folds; generic raw-command and self-command
equivalence; streamed config delivery; effect dispatch; and adversarial shell quoting. `EnsureSpec` covers
WSL diagnostic classification, UTF-16-shaped output normalization, and `bcdedit` arguments. The shared
decorated/multiline-aware source guard enforces the exact dependency boundary and that `Ensure.Wsl2` does
not import the provider realization. The focused `EnsureSpec`/`LiftSpec`/`CordonSpec` gate passed 128/128
with `-Werror` on 2026-08-09 (aarch64-osx, GHC 9.12.4).

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 1478/1478 on
2026-08-09 (aarch64-osx, GHC 9.12.4).

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — where reconcilers sit between the host floor and the plan.
- `documents/architecture/hostbootstrap_core_library.md` — the generic Lift over the pure context vocabulary.
- `documents/architecture/composition_methodology.md` — resolved outer dispatch and nested command folding.

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` — the reconciler contract and the applicability rule.
- `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/engineering/wsl2.md` — the
  provider reconcilers.
- `documents/engineering/accelerator_daemon.md` — the per-substrate accelerator toolchain matrix.

**Cross-references to add:**
- `development_plan_standards.md` § L names this phase as the owner of the reconciler contract.
- `development_plan_standards.md` § U names this phase as the owner of the provider-neutral resolved-tool
  self-reference Lift.
- The [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns the
  plan-bound direct-Colima adapter because it consumes project-plan and admitted-wall evidence.
