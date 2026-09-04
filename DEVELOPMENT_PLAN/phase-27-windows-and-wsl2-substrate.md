# Phase 27 — Windows and WSL2 substrate

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: windows
**Gate**: live `hostbootstrap run -- test run all` reporting `10/10 passed` on a native Windows host

> **Purpose**: Add the Windows-only native host-wall backend and CUDA worker, exercise WSL2 as the Windows
> realization of the universal `linux-cpu` substrate, and confirm the additional Windows behavior.

## Phase Objective

This is an **acceptance phase** (§ II). Nothing depends on it, so a machine without Windows stops at the
worked-demo phase. It carries exactly one substrate beyond the baseline.

Windows is the outer host realization that most exercises the exclusive-global-state machinery, because the WSL2 wall is a
single host-global configuration file every distro shares — which is why the portable host-wall driver exists at
all.

## What this phase confirms

- the WSL2 provider's full lifecycle, including that teardown restores the wall **before** any global shutdown;
- the Windows ownership row — declared by the
  [four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)
  and compiled on every gate host — against the real Win32 surface, with exact status preservation;
- the managed wall body whose idle timeouts determine whether the wall can be released, sized against the
  observed gate duration rather than an assumed one;
- host-native accelerator placement behind a local-only node port with the CUDA worker on Windows;
- that a long-running gate launched from an agent harness survives, using the durable-run mechanism rather than a
  naive background launch.

What this phase does **not** confirm is that the host static gate passes on a Windows outer host. That is
a § JJ obligation every phase holds over its own suites, discharged on the ordinary host static gate long
before this acceptance phase is reached, and Windows is an outer host realization there rather than a
declared substrate. This phase's gate is the live `10/10` demo run and the Windows-only behavior above.

## Sprints

### Sprint 27.1: WSL2 provider acceptance [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/test/Wsl2Spec.hs`
**Substrates**: windows
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

Confirm the Phase 15 (host providers and the self-reference lift) WSL2 lifecycle realization against the
native Windows/WSL host surface.

#### Deliverables

- `ensure wsl2` reconciles the distro; provisioning applies the project's declared sizing.
- The durable host-path share is mounted through the per-substrate primitive, so the guest sees the host's durable
  root rather than a copy.
- Teardown restores the host wall before `wsl --shutdown`, in that order, because the shutdown is what makes a
  wall change take effect.
- The guest alias uses the shared clause-holding backend; all three provider guests run the same Linux image, so
  one backend serves every lane.
- The target record and inner `wsl -d ... --` renderer come from the lower lift-context phase, prerequisite
  diagnostics come from the ensure-reconcilers phase, and the provider lifecycle builders come from the
  host-providers phase; this sprint confirms rather than redefines those boundaries.

#### Validation

`Wsl2Spec` covers the argument shapes, the share primitive, and the restore-before-shutdown order.

#### Remaining Work

None.

### Sprint 27.2: The Windows row against a real Windows kernel [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs`
**Substrates**: windows
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

Confirm the Windows ownership row against the kernel it names, which no other host can do.

#### Deliverables

- The row itself belongs to the
  [four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md),
  which declares both platform rows and the one selector between them. This sprint introduces no
  implementation of it; a second one would be the second answer § LL exists to prevent.
- What this sprint owns is the confirmation: `Win32` handle identity, reparse-point refusal, atomic
  no-replace publication, and write-through replacement exercised where those calls are real. On every
  other gate host the same cases assert the row's declared refusal (§ JJ), which is a smaller claim and a
  true one.
- Exact status preservation is confirmed rather than flattened, so a recovery decision that depends on
  distinguishing two failures can actually make it.
- The finite idle timeouts and the restore-then-shutdown order are observed against a live WSL utility VM,
  which is the only place "the wall is releasable" is a fact rather than a constant.

#### Validation

`WslGlobalWallWindowsSpec` covers the entrypoints, status preservation, and the shared transformer. Dated
evidence: the row passed its focused entrypoint gate and passed inside the complete Windows core suite.

#### Remaining Work

None.

### Sprint 27.3: Windows acceptance [Active]

**Status**: Active
**Implementation**: the whole tree
**Substrates**: windows
**Docs to update**: `documents/engineering/durable_windows_runs.md`,
`documents/operations/demo_runbook.md`

#### Objective

Confirm the current build on this substrate.

#### Deliverables

- From a pristine host, run `test init` then `hostbootstrap run -- test run all` and record `10/10 passed`.
- Audit the same end state the other acceptance phases audit, plus: the host wall restored to its prior body and
  the distro removed.
- The gate is launched out of the agent harness's process tree using the durable-run mechanism and polled by its
  exit sentinel; a naive background launch is reaped mid-run and produces a false failure.
- Record the observed duration against the same envelope the other lanes use.

#### Validation

The `10/10` report plus the audited end state, recorded together with the current matrix size and live applied
wall observation on the WSL distro.

On 2026-08-27, the current execution workspace identified itself as native Linux and exposed none of
`powershell.exe`, `wsl.exe`, or `cmd.exe`. It therefore cannot launch the Windows durable-run mechanism,
exercise the Win32 ownership row, observe the WSL utility-VM wall, or prove restore-before-shutdown. No Linux
result is substituted for this native Windows acceptance requirement.

On 2026-09-04, a native Windows run used the documented WMI durable launcher after `test init` completed.
The `hello-world` variant passed all five cases, including the Windows host accelerator daemon and the
destroy path that removed `hostbootstrap-demo-vm`, released the global WSL2 wall, and restored the original
`.wslconfig`. The `hello-universe` variant then failed while Docker extracted the freshly pulled published
base image: `unpigz` reported a corrupted layer with a CRC32 mismatch. The report was `5/11 passed`: its five
`hello-universe` cases were `BROKEN`, and its additional teardown row was `LEAKED?` because reverse lifecycle
retained unsettled work after the failed bring-up. This is failure evidence, not the phase gate.

A durable retry on the same date exited 1 immediately after reporting `Up to date` and produced no acceptance
report. It therefore supplies no replacement gate evidence and leaves the interrupted lifecycle state to be
diagnosed through the repository's supported recovery path.

#### Remaining Work

Diagnose the immediate retry refusal and reconcile the retained failed-`hello-universe` lifecycle through the
supported recovery path, without deleting the distro or durable records by pathname. Then rerun the complete
acceptance gate from a pristine state through the documented durable-run launcher. The passing run must
exercise typed frame-indexed teardown descent across the real WSL boundary, report `10/10 passed`, and finish
with a current provider-lifecycle observation including wall restoration before shutdown and distro removal.

## Remaining Work

Sprint 27.3. Sprints 27.1 and 27.2 are closed. The failed `hello-universe` bring-up first requires supported
recovery of its retained lifecycle state; the complete matrix then requires a pristine durable rerun and the
end-state audit that the host wall is restored to its prior body and the distribution is gone.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — Windows classification and the provider dispatch.

**Engineering docs to create/update:**
- `documents/engineering/wsl2.md` — the provider, the wall, and the restore ordering.
- `documents/engineering/durable_windows_runs.md` — why a long gate must leave the harness process tree.
- `documents/engineering/accelerator_daemon.md` — the CUDA-on-Windows worker and its placement.

**Cross-references to add:**
- `CLAUDE.md` and `AGENTS.md` state the durable-run requirement for assistants on Windows.
- `documents/operations/demo_runbook.md` — the Windows sequence.
