# Phase 27 — Windows and WSL2 substrate

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: windows
**Gate**: repository Python-bootstrapper `poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed` on a native Windows host, followed by the terminal ownership and WSL wall audit
**Gate kind**: deferred
**Gate evidence**: 2026-09-11 ; x86_64 Windows 11 Home 10.0.26200, AMD Ryzen 7 5700G, 15.87 GiB,
NVIDIA GeForce RTX 3090 driver 616.64, WSL 2.7.10.0 (kernel 6.18.33.2-2), GHC 9.12.4, Cabal 3.16.1.0,
Poetry 2.4.1, repository-venv Python 3.14.7 ; repository Python bootstrapper
`poetry run hostbootstrap run --project-root demo test run all`, launched through the harness-owned
durable Windows launcher ; pass ; covers
dbd7ee8515737e4c8391a9337a1815eb7db8de2d6dc28a4893e0b099b669b83e
**Evidence covers**: `core/hostbootstrap-core/src` `core/hostbootstrap-core/internal` `demo/src` `demo/app` `demo/test` `demo/docker` `hostbootstrap`

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

## What one Windows visit records

This phase declares exactly one substrate beyond the baseline (§ II), and its gate is the live Windows
matrix. The same machine is also a Windows gate host, so a visit to it records two cells (§ JJ):

| Cell | Owned by |
|---|---|
| Windows substrate acceptance | this phase |
| Windows gate host, host static gate | [phase 28](phase-28-host-portability-acceptance.md) |

A Windows host can additionally present an x86_64 Linux gate host through WSL2, which § JJ admits as a
Linux gate host in its own right. That is a convenience rather than a requirement: the x86_64 Linux cell
is already produced by the Linux/NVIDIA visit, and no cell is owed to two machines at once.

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

### Sprint 27.3: Windows acceptance [Done]

**Status**: Done
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

On 2026-09-05, a native Windows run used the documented WMI durable launcher and passed the complete
`10/10` matrix in 2 hours 54 minutes. Both `hello-world` and `hello-universe` passed pristine bootstrap,
web build, end-to-end tabs, registry persistence, and durable readback. The run exercised the Windows host
accelerator daemon and typed frame-indexed teardown across the WSL boundary. Its final destroy removed
`hostbootstrap-demo-vm`, released the global WSL2 wall before shutdown, restored the exact prior CRLF
`.wslconfig` body, and left no WSL distribution or utility-VM process.

#### Remaining Work

None.

### Sprint 27.4: The Windows acceptance run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: windows
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated live acceptance matrix on a native Windows host.

#### Deliverables

- Initialize the pristine demo from the repository root with the bootstrapper's harness `test init`
  entry on the native Windows gate host.
- Run the repository Python bootstrapper's complete-matrix harness entry through the documented Windows
  durable-run mechanism and record `10/10 passed`, the host/toolchain, duration, run IDs, and image digests.
- Audit closed run leases, released ownership, removed generated config and WSL distro, preserved durable
  parent, and restoration of the prior WSL wall body before global shutdown.
- Record passing gate evidence and its covered-source digest only after the live matrix and audit pass.

#### Validation

The gate host is native x86_64 Windows 11 Home 10.0.26200 with an AMD Ryzen 7 5700G, 15.87 GiB of host
memory, and an NVIDIA GeForce RTX 3090 on driver 616.64. Its toolchain is GHC 9.12.4, Cabal 3.16.1.0,
Poetry 2.4.1, repository-venv Python 3.14.7, Docker CLI 29.6.1, and WSL 2.7.10.0 on kernel 6.18.33.2-2.
The substrate detector classifies it `windows-gpu` (amd64) and the fail-fast host minimums pass.

The current-source static preflight passes on that host: the warning-clean core build and the complete
core gate at 2,500/2,500 in 329.88 seconds, the Python code check and 235/235 tests, and the demo
warning-clean build with 149/149 tests. The 208-file covered source measures
`dbd7ee8515737e4c8391a9337a1815eb7db8de2d6dc28a4893e0b099b669b83e`.

The harness `test init` entry writes the operator-owned `.build/hostbootstrap-demo.test.dhall`, which
declares 6 CPUs, 10 GiB memory, 80 GiB storage and the two stable variants and measures SHA-256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`. The repository Python
bootstrapper's complete-matrix entry then runs through the harness-owned durable Windows launcher, which
creates the process outside the agent harness's tree. It starts at 2026-09-11 01:28:44 UTC, exits 0 at
04:26:15 UTC after 10,651 seconds (2 hours 57 minutes 31 seconds), and reports exactly `10/10 passed`.
A gate of that length surviving an agent-driven session is itself the durable-run confirmation this
phase declares; no naive background launch is used.

Both `hello-world` (`run-7a1188be2e68`) and `hello-universe` (`run-7eeb3f4ea634`) pass pristine
bootstrap, web build, end-to-end tabs, registry persistence, and durable readback. The matrix performs
four pristine generations, each in its own freshly installed Ubuntu 24.04 distribution, taking the
per-user global WSL2 wall at fences 23, 24, 25, and 26. Every generation pulls published CPU/amd64 base
digest `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5` without Docker
layer-cache reuse, runs the in-image quality gate and export checks, and publishes its derived image to
the run-local registry:

| Variant | Generation | Derived image digest |
|---------|------------|----------------------|
| `hello-world` | 1 | `sha256:8997e96ad7e45b71d888b1d51b80227c6e79540cac96ebb4a474cfcac851032d` |
| `hello-world` | 2 | `sha256:de2d2bcfa28c033d6f0d46339021cb6e7181a04f82ca153f9a2ca55b79648a8b` |
| `hello-universe` | 1 | `sha256:0c872c258e4cc260e87219bcb0fb00b163e5bfc6218956087d9c5f1414da685a` |
| `hello-universe` | 2 | `sha256:9e388ac4f0c17d23393824b6db4886bde36f300f3914a76cd706305e9e3f33d8` |

Each of the four bring-ups warns that applying the wall ceiling runs a global cross-distro shutdown before
taking its fence, and each of the four teardowns reports releasing the global wall and restoring the
original `.wslconfig` body ahead of any global shutdown. The managed wall body's idle timeouts hold the
guest across the full observed 2-hour-57-minute duration, so the sizing is measured against this run
rather than assumed. The Windows ownership row runs against the real Win32 surface throughout. All four
generations install, measure, and launch the hidden Windows host accelerator daemon, which resolves the
WSL2 cluster exposure and serves a loopback-only `ws://127.0.0.1` endpoint; each waits for that daemon to
build its worker and connect, and each end-to-end case passes against it.

The terminal audit finds both leases `closed`, at epochs 4 and 8, and both profiles `available`. No
project mode, generated-config, or data-root record remains, the generated
`.build/hostbootstrap-demo.dhall` is gone while the operator test config remains at its exact hash,
`.test_data` exists and is empty, and neither run data directory survives. No WSL distribution is
installed, the utility VM is stopped, and no demo daemon or detached matrix process runs. The restored
`.wslconfig` measures its exact original SHA-256
`2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694` and no active wall record remains.
The terminal 208-file source measurement still matches the in-run
`dbd7ee8515737e4c8391a9337a1815eb7db8de2d6dc28a4893e0b099b669b83e`.

#### Remaining Work

None. This run confirms the Windows-only wall, ownership, and accelerator behavior; the
[worked-demo phase](phase-24-worked-demo.md) owns the same run's universal `linux-cpu` matrix claim.

### Sprint 27.5: The Windows and WSL2 acceptance against the current tree [Active]

**Status**: Active
**Implementation**: none — this sprint records a run
**Substrates**: windows
**Docs to update**: `documents/engineering/testing.md`

#### Objective

This phase's evidence covers the host-portable tree, so ordinary source change expires its claim —
which § G names as the expected state for an acceptance phase between runs rather than as an unclosed
phase. The claim is re-established by running the gate on a Windows host, not by re-recording a digest
over a tree nothing re-tested. That visit also carries the Windows gate host, and it confirms the demo's daemon claims survive a killed predecessor.

#### Deliverables

- The phase's declared gate is re-run in full on the hardware it declares.
- A gate-evidence row records the date, the gate host, the command as run, and the result.
- The row names which program ran where two share a name, and prefers an invocation against the tree over a separately installed one.
- The covers digest is re-measured over this phase's own paths and recorded.
- Every cell this hardware can produce is recorded in the same visit, so the machine is not owed a second one.

#### Validation

The phase's own gate, on its own hardware. Re-recording the digest without the run is the one thing
this sprint may not do.

#### Remaining Work

The run is owed at the next visit to this hardware. It is taken once no other phase carries open
work, because any earlier source change re-owes it.

## Remaining Work

The Windows and WSL2 acceptance is owed against the current tree. **Sprint 27.5** owns
the re-run, at the next visit to the hardware this phase declares.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — Windows classification and the provider dispatch.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
- `documents/engineering/wsl2.md` — the provider, the wall, and the restore ordering.
- `documents/engineering/durable_windows_runs.md` — why a long gate must leave the harness process tree.
- `documents/engineering/accelerator_daemon.md` — the CUDA-on-Windows worker and its placement.

**Cross-references to add:**
- `CLAUDE.md` and `AGENTS.md` state the durable-run requirement for assistants on Windows.
- `documents/operations/demo_runbook.md` — the Windows sequence.
