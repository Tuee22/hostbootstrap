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

The 2026-09-16 visit is on native x86_64 Windows 11 Home 10.0.26200 with an AMD Ryzen 7 5700G,
NVIDIA GeForce RTX 3090 driver 616.64, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1, and
repository-venv Python 3.14.7. The repository Poetry environment is resolved from `pyproject.toml`.
The Python code check passes, and the Python suite passes 251/251 in 4.50 seconds.

The pristine preflight finds no demo build, protected state, test-data root, running daemon, or installed
WSL distribution. The original `.wslconfig` measures SHA-256
`2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`.
The 211 covered source files measure
`cbbaa6b6e13052bd9e4adb981b64b0de86a34b2d10c0bd0797118b1720e1165b` before the run.
The repository bootstrapper's `test init` entry begins a cold native dependency build. Initialization
is stopped before any live infrastructure is created when the native core preflight exposes ownership
compilation defects. The live matrix and terminal audit have not run; the recorded preflight digest
precedes those source corrections.

The ownership phase then closes on the complete native Windows static gate, recorded in Sprint 28.5.
The corrected 211-file tree measures
`8da152c4d873b944b38e6edde69f838150ff75ad0e3f2218970bba2d4c5da689`.
Initialization resumes its isolated dependency cache through the harness-owned WMI durable launcher
on 2026-09-16 at 16:29:57 UTC and succeeds in 677.81 seconds. The resulting operator test config
declares 6 CPUs, 10 GiB memory, 80 GiB storage, and both stable variants; its SHA-256 is
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The complete matrix starts at 16:41:14 UTC and fails at 17:25:09 UTC after 2,634.63 seconds.
It does not produce a passing matrix result.

The first `hello-world` generation (`run-5e9e819c7984`) takes wall fence 27 and installs Ubuntu
24.04.5 LTS on Linux 6.18.33.2-microsoft-standard-WSL2. Read-only guest observations report 6 CPUs,
10,184,824 kB total memory, and a 79 GiB formatted root filesystem from the declared 80 GiB VHD.
The applied wall carries both 21,600,000 ms idle timeouts, 6 processors, 10 GB memory, and 10 GB swap.
Its native Linux bootstrap succeeds and Docker pulls published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8` before building the
derived project image.
The in-image Haskell quality gate and warning-clean component build pass. The following `spago build`
step crashes with exit 139 after fetching the web dependencies. The guest kernel identifies the faulting
process as Node's `V8Worker`, on Node 24.21.0 with Spago 1.0.4 and PureScript 0.15.16; no out-of-memory
kill is reported, and the guest has ample free memory. The retained guest is used to isolate that failure
before any acceptance retry. No image, browser, durable-readback, or terminal-cleanup success is claimed.
Three isolated cold `spago build` attempts then pass against copies of the same web source in fresh
containers from that exact base, with no source, toolchain, or runtime-flag changes. The diagnostic
containers are removed. The observed crash is not reproduced; a complete matrix retry is still required,
and these diagnostic builds do not replace any acceptance assertion.
Immediate matrix retries correctly refuse the retained guest through the production-state safety
precondition. The failed run's lease is closed at epoch 2, its generated config is absent, and its
test-data parent is empty. Recovery verifies the guest was created by this run, restores the exact
recorded wall through `restoreCurrentUserGlobalWall` with the demo's own identities and managed body,
confirms the original wall hash and absence of an active wall record, unregisters only
`hostbootstrap-demo-vm`, and then shuts down WSL. This restores the disposable starting state before
the full matrix is retried; it is recovery from a failed attempt, not terminal acceptance evidence.
The fresh matrix starts at 17:32:52 UTC with `hello-world` run `run-616fb00242bc`, wall fence 28,
and a new guest. Its Haskell quality gate, web build, and exported-image verification pass; the image
is `sha256:a6cd16913128d4f4de2d40b490bcb257ddf47c79f48e52295c561b5ce956ccd9`.
Cluster, MinIO, and registry startup pass, but `kind load docker-image` fails while containerd extracts
base layer `sha256:38a805fdab2cdb3d77d236a7bb01c6474779819896dce79d04de3a017ab17e5d`, reporting
that its content digest is absent. This guest uses Docker 29.1.3 and containerd 2.2.1 from Ubuntu.
The failed variant's teardown removes its guest and restores the wall. The same matrix proceeds to
`hello-universe`, run `run-63fb0aa62f0c`, wall fence 29.
An isolated image-import probe in that guest uses the same published base, Docker's containerd image
store, Kind 0.33.0, Kubernetes 1.37.0, and node containerd 2.3.4. A new derived image retaining every base
layer loads successfully through the unmodified `kind load docker-image` command into a fresh probe
cluster. The previously missing layer is present, no disk-pressure event is observed, and at least
28 GiB remains free. The probe cluster, client container, and derived-image tag are removed. This does
not reproduce the project-image failure or establish an export workaround; no image-loading source
change is made on that evidence.
The actual `hello-universe` image is
`sha256:aeffc3237f399ee61235090501040b64d02b8f5caa912ccbb68f8ed50348d584`. Its unmodified import
also succeeds at 19:02:44 UTC. Inspection of the completed archive finds every referenced manifest and
layer, and the previously missing digest is observed in the node's content store both before and after
extraction. The guest retains 23 GiB free at import completion. Registry push, web exposure, and hidden
native Windows daemon launch then succeed. The first variant's failure still prevents this attempt
from satisfying the complete matrix gate; no source workaround is inferred from the successful retry.
The variant reaches its durable-readback recreation: teardown deletes the guest and restores the
original wall before a new guest takes wall fence 30.
That generation builds image
`sha256:9e5047540574a932bdaec49f28555a40fd48388040d8088a69abf6504facd769`; its unmodified cold import
succeeds at 19:57:05 UTC, and durable readback passes. The matrix finishes at 19:58:01 UTC after
8,709.16 seconds with exit 1 and `5/11 passed`: all five `hello-universe` cases pass, while the failed
`hello-world` bring-up produces five `BROKEN` rows and one `LEAKED?` teardown row naming open session
`chain-3-c37c8e1e7f3b`. The generated config and run data are absent, the original wall hash is restored,
and the three attempt leases are closed at epochs 2, 4, and 8. The open failed-run session nevertheless
remains recorded. Focused regression tests then confirm that the short close accepts a retained
no-effect proof after either a session opens or an effect appears. The recursive-lifecycle phase owns
the current-state recheck; these results do not establish current-source Windows acceptance.

A separate native process probe links the built ownership library and uses the daemon's exact
`hostbootstrap-demo.accelerator.owner` key and `hostbootstrap-demo/accelerator-daemon\n` payload
in a temporary protected store. A live holder excludes a competing entry. After `Stop-Process -Force`
kills the holder without running its bracket finalizer, a successor immediately acquires the entry,
observes the unchanged store identity and owner bytes, refuses an `ExpectAbsent` overwrite, and removes
the owner only with its observed version. All assertions pass. This is evidence for the native claim
primitives used by the daemon; the complete demo suite separately verifies those are its two claim
implementations. It does not claim a live daemon was killed during the acceptance matrix.

The protected short-close correction then passes the complete native Windows and independent x86_64
Linux static gates, recorded in Sprint 28.5. The worked demo's complete Production sequence also passes
on Windows through WSL2, including an unmodified image import, native daemon startup, and terminal wall
restoration. The new 211-file covered-source measurement is
`4e2da7028532e4bfc2b87064e4ea19ebe2342c2ac6d53473e763757ced5fdd0f`.
The complete current-source matrix runs through the durable Windows launcher from 21:26:26 UTC to
22:08:19 UTC, with `hello-world` run `run-6e2eb13b6da4` and wall fence 32. It exits 1 after
2,512.69 seconds, reporting `0/12 passed`. Native bootstrap, image build, web build, exported-runtime
verification, and cluster/registry startup pass. Image
`sha256:ee491414a6ade98ed91c0562a84193bf71102177ebc425a86cefc5ea5b197b95` then fails the unmodified
Kind import: containerd reports `archive/tar: invalid tar header` while extracting base layer
`sha256:b65cecff0b9ba303a7fadf8f2fdf7b90ea54565c130af48a22ce518fceed8b09`.
This differs from the earlier missing-content error. Teardown removes the guest and restores the exact
original wall, but session `chain-12-180a75c05484` remains open. The new short-close check refuses the
old generation-12 close authority after teardown advanced the bound lease and mode to generation 13.
Those records remain recoverable, and all five `hello-universe` cases are refused because prior cleanup
is unresolved. No passing acceptance or clean terminal ownership audit is claimed.
The ordinary recovery retry at 22:11:32 UTC exits 1 with `0/10 passed` before creating a guest. It
misparses `project:ensure-vm-provider` as an operation of session `project`, exposing the session-key
enumeration defect now owned by Sprint 10.5. That correction expires the preceding source measurements.
Independent inspection of the exact failing layer downloaded from Docker Hub verifies its SHA-256,
gzip CRC, and all 16,895 tar entries; this does not identify the local extraction failure's cause.

Isolation outside the project reproduces extraction failures in a newly provisioned Ubuntu 24.04
WSL distribution using Docker 29.1.3, containerd 2.2.1, and pigz 2.8 with zlib 1.3. Two ordinary pulls
of the published CPU/amd64 base fail on different layers: one reports an invalid tar header and the
other an `unpigz` CRC32 mismatch. Restarting the otherwise idle WSL utility VM permits the exact base
digest to pull successfully. A fresh standalone Kind cluster subsequently fails its first cold import
of that base; the probe cluster is removed. No project image-loading or host configuration change is
made to hide these failures.

The second failing compressed layer, downloaded independently, has the expected SHA-256. Three
`unpigz` passes and one GNU gzip pass each validate all 16,088 tar entries. Separately, HLint in the
base container segfaults once and the identical command passes on retry. These observations establish
intermittent failures outside the project but do not identify a kernel, hardware, or decompressor cause.
Separate one-pass memory tests of 512 MiB and 2 GiB pass; they are not a complete hardware assessment.

The settled-source recovery retry runs through the repository Python bootstrapper and durable launcher
from 23:01:51 UTC to 23:02:18 UTC, exits 1 after 26.52 seconds, and reports `0/10 passed`, all
`REFUSED`. The corrected session parser permits recovery to close `chain-12-180a75c05484` at generation
16. The canonical resource check then correctly refuses a pre-effect close: the provider and share
records remain `owned`, and the Harness mode and bound lease remain at generation 17. The ordinary
command installs the refusing recovery executor, and this retry does not establish a settled resource
forest. No record is manually rewritten or deleted to admit another run.

No project guest or generated project config remains, `.test_data` is empty, the operator test config
retains its exact hash, and the original `.wslconfig` hash is restored with no active wall record.
Production durable data remains. This is a failed-run audit, not a clean terminal ownership audit:
the unresolved Harness lease still excludes Production and subsequent Harness runs. The final
211-file source measurement is
`a8d4c1f2c21b08381d6a4b2cd7c6c2268aea7c1ef7512435a18e0454be852e90`.

#### Remaining Work

Resolve the preserved run's canonical provider/share ownership through verified recovery, establish a
stable image-import substrate, and run the full matrix through the durable Windows launcher. Record
`10/10`, image identities, duration, and a clean terminal ownership audit against the measured source.

## Remaining Work

**Sprint 27.5** owns the complete Windows matrix and terminal audit. The final-source retry closes the
abandoned session but refuses the remaining canonical resource ownership. A verified settlement of that
run and a stable image-import substrate are prerequisites to the owed complete matrix.

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
