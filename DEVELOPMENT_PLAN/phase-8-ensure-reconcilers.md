# Phase 8 — Ensure reconcilers

**Status**: Active
**Depends on**: Phase 7 (Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: Bring each host dependency to a declared state idempotently, with substrate applicability
> decided by the classified substrate rather than attempted and caught, and supply the generic resolved-tool
> self-reference Lift that crosses already-described frame contexts.

## Phase Objective

Once the binary exists it can install what it needs. Each `ensure` reconciler answers one question — is this
dependency present at the required version, and if not, install it — and answers it idempotently, so a second
run is a no-op rather than a reinstall. Applicability is derived from the classified substrate, so a
reconciler that cannot apply reports that rather than failing.

The accelerator and host-realization reconcilers beyond universal `linux-cpu` are written here; their live confirmation belongs to
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

### Sprint 8.3: Accelerator and outer-host provider reconcilers [Done]

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

### Sprint 8.5: Reconcilers as frame rows [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Make a reconciler a row over one closed frame table (§ LL), so which hosts it applies to, how those hosts
are described, and what it installs on each are three views of one value.

#### Deliverables

- `HostFrame` is the closed three-constructor frame axis, and `substrateFrame` is the one place the five
  classification tags collapse onto it. `isLinux`, `isWindows`, and `isAppleSilicon` are derived from that
  single fact rather than each spelling its own constructor pair.
- The accelerator is a capability *of* a frame rather than a frame of its own: a row that needs one says so
  with `rowRequiresNvidia`, and `frameTable` orders accelerator rows first so a table carrying both selects
  the specific one.
- `Reconciler` carries a `FrameTable`. `appliesTo`, `requirement`, and `reconcilerInstallSteps` are derived
  from it, so a reconciler that claims a host its own plan refuses is unrepresentable.
- A frame another frame owns is an **absent row**: `ensure incus` has apple and linux rows and no Windows
  row at all, because the WSL2 frame owns the Windows host provider and a second refusal is a second answer
  to one question.
- `ProvidedElsewhere` is the row that applies — the dependency is probed in this frame — but delegates the
  install, so "Docker on apple-silicon comes from Colima" is a row rather than a refusal.
- `checkHostMinimums` and `capacityReadPlan` route on the frame, so a new classification tag cannot silently
  miss a case that reads as exhaustive.

#### Validation

`EnsureSpec`'s frame-table group asserts the agreement itself on every reconciler and every host: an
applicable host has a plan, an inapplicable one gets exactly the diagnostic `decide` returns, and the
requirement each diagnostic quotes is the rows' own rendering. The accelerator-row and absent-row cases
cover selection and delegation. `SubstrateSpec` covers the frame collapse and the derived predicates.

#### Remaining Work

None.

### Sprint 8.6: The guest bootstrap vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`core/hostbootstrap-core/test/GuestBootstrapSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/build_and_run_model.md`

#### Objective

Own the one residue § KK names: the closed, ordered set of steps that establishes the binary inside a fresh
frame, before any of the binary's own typed operations can run there.

#### Deliverables

- `HostBootstrap.Ensure.GuestBootstrap` is the sole owner. `GuestPackage` is the closed guest floor,
  `PinnedToolchain` the pinned GHC, and `GuestBootstrapStep` the five steps — floor, toolchain, Python
  bootstrapper, host-native build, install — each separate because each is separately probeable.
- `guestBootstrapPlan` is total over the step constructors and fixes the order, so a caller selects the
  target and never the sequence.
- Every step renders to argument vectors: `stepProbe` answers with an exit status alone, and `stepActions`
  is a list precisely so the two shapes that reach for an interpreter do not need one — a piped installer is
  a fetch step followed by a run step, and a working directory is an argument to `env`.
- `mkGuestBootstrapTarget` is the only constructor and admits POSIX-absolute guest paths alone (§ MM), so a
  drive-qualified outer-host path cannot reach a Linux guest process as a relative path.
- `runGuestBootstrapWith` is the probe-first driver — probe, act on absence, re-probe, stop at the first step
  that will not settle — the control flow `installAndVerify` holds for a host reconciler (§ L), over a frame.
- The pinned-toolchain probe requires the installer, the exact versioned GHC executable, and Cabal together;
  an interrupted installer therefore remains absent and the same step resumes instead of admitting a partial
  toolchain to the host-native build.
- Every leaf folds through `HostBootstrap.Lift`, so the crossing into the frame is the one fold's (§ LL) and
  this module renders none of it.

#### Validation

`GuestBootstrapSpec` covers the target's guest-path admission and its three refusals; the plan's order,
totality, and floor; that no rendering hands a program to an interpreter and no argument carries a Windows
separator; the exact probe argv of every step; and the driver's four control-flow outcomes against an
injected leaf runner — satisfied frame, empty frame, failed action, and a step that never settles.

Dated evidence for the phase gate: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and
Cabal 3.16.1.0 passed `cabal test all --ghc-options=-Werror` from `core/` host-native at 1,922/1,922 in
234.62 seconds, together with `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed. That run is evidence for the one gate host that
produced it (§ II); confirming the same gate on the remaining gate host families belongs to the
[host-portability acceptance phase](phase-28-host-portability-acceptance.md).

On 2026-09-01, after tightening the interrupted-toolchain probe, the Windows host-static gate passed again:
`cabal test all --ghc-options=-Werror` reported 2,477/2,477 in 725.28 seconds,
`poetry run python -m hostbootstrap.check_code` passed, and
`poetry run python -m hostbootstrap.test_all` reported 231/231.

#### Remaining Work

None. The worked-demo phase adopts this vocabulary at its own pristine-host call site; a live confirmation
is not a closure obligation of this static phase (§ C, § II).

### Sprint 8.7: A dispatched command names a real executable [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/library_hierarchy.md`

#### Objective

§ K makes a bare command name unrepresentable at host-tool resolution. One layer up, the lift's raw
command leaf is a plain list, and the fold over an empty one produces a dispatch naming the empty
string — the same illegal shape, reachable by a different route. Beside it, the self-reference value
holds two adjacent unvalidated paths with both its constructor and its accessors exported, so a handed
value can be re-pointed and the two paths can be swapped.

#### Deliverables

- The raw command leaf carries a non-empty argument vector, so the equation that dispatches an empty executable has no reason to exist and is deleted.
- The self-reference value's two paths are distinct newtypes, so they cannot be transposed.
- Its constructor and its field accessors are both hidden — an exported accessor still admits record update, which is the half that matters.
- A compile-fail fixture pins that a caller cannot re-point a self-reference it was handed.

#### Validation

The host static gate, plus the new fixture. The lift suite covers the dispatch shapes.

#### Remaining Work

The reconciler workflow and the accelerator probe are Sprints 8.8 and 8.9.

### Sprint 8.8: One group-and-socket reconciler workflow [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Two reconcilers hold the same workflow: read the environment, find the invoking non-root user, skip
with a message when there is none, add that user to a group, verify, then grant the socket. They differ
in a group name, a socket path, and a label. § LL calls a second copy of one workflow a defect because
each copy passes its own tests — and the exit-code formatting inside them is repeated nine times
across the two files.

#### Deliverables

- `Ensure.hs`, which already owns the shared reconciler vocabulary, gains the group-and-socket workflow parameterised by group, socket, and label.
- Both reconcilers become applications of it.
- The three-way exit-code report is written once.

#### Validation

The host static gate. The ensure suite already pins each reconciler's messages; unchanged messages are
the evidence that the shared workflow is the same workflow.

#### Remaining Work

None beyond the phase's own.

### Sprint 8.9: One accelerator probe [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/CudaWin.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

The question "does the accelerator tool report a device" is answered by four separate
implementations — twice with identical bodies in one module, once inline in its Windows neighbour, and
once more in substrate detection. One of them is the answer; the others are copies of it.

#### Deliverables

- The probe has one implementation, shared by the reconcilers that ask it.
- Substrate detection's marker list and this probe agree by construction rather than by inspection.
- The duplicate bodies are deleted.

#### Validation

The host static gate.

#### Remaining Work

None beyond the phase's own.

## Remaining Work

The lift's dispatch leaf is owed a type that cannot name an empty executable.
**Sprint 8.7** owns it. Sprints 8.8 and 8.9 follow with the shared reconciler workflow and the single
accelerator probe.

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
