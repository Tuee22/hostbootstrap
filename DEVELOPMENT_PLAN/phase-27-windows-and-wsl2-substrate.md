# Phase 27 — Windows and WSL2 substrate

**Status**: Done
**Depends on**: Phase 24 (the worked demo)
**Substrates**: windows
**Gate**: repository Python-bootstrapper `poetry run hostbootstrap run --project-root demo test run all`
reporting a complete pass of the configured matrix on a native Windows host, followed by the
terminal ownership and WSL wall audit
**Gate kind**: deferred
**Gate evidence**: 2026-10-22 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 Home
10.0.26300.9457, AMD Ryzen 7 5700G, 63.87 GiB, RTX 3090 driver 617.42, CUDA 13.3,
WSL 2.7.10.0, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1, repository-venv Python 3.14.7 ;
repository Python bootstrapper `poetry run hostbootstrap run --project-root demo test run all`,
launched through the WMI durable runner, followed by the terminal ownership and WSL wall audit
and `wsl.exe --shutdown` after verified wall restoration ; pass ;
covers ecf6b4522ebbd983f3f702fe6b95e14c7d1c3843811b7fb0c781b3a5a094d0e7
**Evidence covers**: `core/hostbootstrap-core/src` `core/hostbootstrap-core/internal` `core/hostbootstrap-core/app` `core/hostbootstrap-core/test` `core/hostbootstrap-core/provider-live` `core/hostbootstrap-core/hostbootstrap-core.cabal` `core/cabal.project` `hostbootstrap` `pyproject.toml` `demo/src` `demo/app` `demo/test` `demo/hostbootstrap-demo.cabal` `demo/cabal.project` `demo/docker` `demo/chart` `demo/playwright/package.json` `demo/playwright/playwright.config.ts` `demo/playwright/tests` `demo/web/spago.yaml` `demo/web/src/Main.purs` `demo/web/src/index.js` `.dockerignore` `fourmolu.yaml` `.hlint.yaml`

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

### Sprint 27.5: The Windows and WSL2 acceptance against the current tree [Done]

**Status**: Done
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

The live gate's scope includes the core and consumer components compiled by the in-image
`check-code`, package/project and bootstrap metadata, authored chart, browser and SPA inputs, and
committed style and Docker-context contracts. A change to those inputs can change the declared gate
without changing provider code. Generated bridges, caches, runtime state, and external toolchains
remain outside this authored-source set.
The 25 roots contain 845 files and remeasure unchanged after the gate on 2026-10-16 as
`cb608a90e5ca585ddd064cfc69010e02283159d44c926bda4b273a8bb8f3e10b`.
The source and authored fixture bytes remain unchanged throughout `phase24-matrix-20261015`.
The completed native static gate, Production sequence, complete passing matrix, and terminal audit
establish this expanded Windows acceptance.
The 212-file measurements below retain their original narrower subset meaning.

The earlier Windows pass retains its original narrower scope: `core/hostbootstrap-core/src` `core/hostbootstrap-core/internal` `demo/src` `demo/app` `demo/test` `demo/docker` `hostbootstrap`.
Its dated result and original digest are preserved without restamping:

- 2026-09-11 ; x86_64 Windows 11 Home 10.0.26200, AMD Ryzen 7 5700G, 15.87 GiB,
  NVIDIA GeForce RTX 3090 driver 616.64, WSL 2.7.10.0 (kernel 6.18.33.2-2), GHC 9.12.4, Cabal 3.16.1.0,
  Poetry 2.4.1, repository-venv Python 3.14.7 ; repository Python bootstrapper
  `poetry run hostbootstrap run --project-root demo test run all`, launched through the harness-owned
  durable Windows launcher ; pass ; covers
  dbd7ee8515737e4c8391a9337a1815eb7db8de2d6dc28a4893e0b099b669b83e

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

On 2026-09-17, the native Linux visit reaches this phase after closing phases 24 and 26 with their
complete gates. No Windows connection is configured in this workspace, and no connection details
have been supplied. The preserved Windows resource forest cannot be inspected or settled from this
host. No recovery mutation, new Windows run, or refreshed Windows acceptance claim is made. The
Linux CPU and NVIDIA successes do not substitute for this phase's native Windows gate.

On 2026-09-23, a native Windows visit finds a different preserved Harness run,
`run-a3ff86b86ff8`, with a bound lease, an open session, and an owned
`core:deploy-vm` provider resource record. The named WSL distribution is stopped.
The repository Python bootstrapper's complete-matrix command is launched through
the harness-owned durable Windows launcher. After a native dependency rebuild,
it exits 1 and reports `0/10 passed`: every case is `REFUSED` because recovery
finds `core:build-pb` at `EffectOutcomeUnknown` and the session classifier reports
that phase as unrecognised. No matrix case reaches a fresh provider bring-up.
This run supplies failure evidence only; it does not satisfy the gate or authorize
manual deletion of the protected records.

On 2026-09-23, an operator-approved reset follows direct guest inspection: the stopped
`hostbootstrap-demo-vm` has the expected staged and installed binary hashes, no demo image or
containers, and no active build process. The preserved run record lacks a WSL instance GUID, so
automatic recovery cannot prove guest identity retrospectively. The generated run state and wall
records are archived at `C:\Users\Matt\AppData\Local\Temp\hb-recovery-archive-20260923`.
`restoreCurrentUserGlobalWall` succeeds; the active wall record disappears and `.wslconfig`
matches its recorded original SHA-256. The named guest is then unregistered successfully, and
WSL reports no installed distributions. The live run state and generated project config are moved
into the archive. A fresh complete matrix is launched through the durable Windows launcher with
label `phase27-reset-20260923`. It exits 1 at 18:07 local time with `4/12 passed`. The fresh
guest completes pristine bootstrap, pulls base image digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, and passes
`hello-world` web build, end-to-end tabs, and registry persistence. At the same-run restart,
the preserved lifecycle records identify the first child failure as
`kind load docker-image hostbootstrap-demo:local --name hostbootstrap-demo-test-run-59079834b964`
exiting 1 during `project:push-image`. The parent reports this as
`handoff relay: lifecycle acknowledgement failed at terminal callback after acknowledgement`:
the completion callback acknowledges a failed child report and returns a failure, which the relay
renders as that generic message. The guest's detailed Kind stderr was not retained by the parent,
so this run alone does not establish the image import's lower-level cause. Failed-Up unwind retains
`project:deploy-registry`, `project:deploy-minio`,
`core:deploy-kind`, `core:context-init`, `core:copy-source`, and `core:deploy-vm`. The
`hello-world` durable-readback case is broken; teardown and mode close cannot prove the remaining
ownership settled, and all `hello-universe` cases are refused. The gate did not pass. The guest
was unregistered and the global WSL wall restored, but protected run records remain for analysis.
An independent `hostbootstrap-image-probe` Ubuntu 24.04.5 WSL distro then installs the same Docker
29.1.3/containerd 2.2.1 family, with Docker's containerd image store enabled. It pulls the exact
published base digest above, creates a fresh Kind 0.33.0/Kubernetes 1.37.0 cluster, and imports
that digest under `hb-probe:local` through unmodified `kind load docker-image` successfully. The
tag is confirmed in the Kind node's `k8s.io` image store. This one successful base import does not
reproduce or explain the failed project-image import in the deleted guest, and it does not prove a
stable substrate across a complete matrix.
On the same Windows host, the host static gate is rechecked against unchanged production source.
`cabal test all` from `core/` passes 2,547 core tests; the first plain `cabal test all` from
`demo/` reports a failed demo suite while its core suite passes, without retaining the failed
assertion in Cabal's summary. The focused demo suite then passes 151/151. A serial rerun of the
complete demo gate with successful cases hidden passes its core, provider-live refusal, and demo
suites. `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` pass, the latter 251/251. This static result does not
replace the failed live matrix or establish that the first demo-suite failure cannot recur.
The 134 protected records of `run-59079834b964` are archived outside the working tree at
`C:\Users\Matt\AppData\Local\Temp\hb-recovery-archive-20260923\failed-run-59079834b964.hostbootstrap`
after confirming the active mode names that Harness run, no project distro or wall exists, and no
hostbootstrap process is running. A fresh complete Windows matrix starts through the durable
launcher as `phase27-retry-20260923b`; its result and terminal audit are pending.
Its first `hello-world` generation completes the previously failing Kind image import and
opens the live assertions. The matrix then releases that generation's WSL wall and starts a
fresh guest for the next lifecycle leg; this partial progress is not gate evidence.
That generation also completes its project-image Kind import and second `hello-world`
assertion leg, then releases its WSL wall. The matrix advances to `hello-universe` in a
third guest at fence 38. This attempt exits 1 with `5/12 passed`: all five `hello-world`
checks pass, including durable readback, but the first `hello-universe` bootstrap fails
while Docker 29.1.3/containerd 2.2.1 extracts the published base image layer
`sha256:8203887b604f75d2e85df1b0682e7298d1dd26ca2a584940d8115ed5389a3421`
(`archive/tar: invalid tar header`). The remaining `hello-universe` checks are broken;
reverse lifecycle and mode close report unsettled ownership. The guest remains installed
for diagnosis, while `.wslconfig` already matches its original SHA-256 and the guest has
67 GiB free disk and 9.0 GiB available memory. This is a failed gate, not acceptance evidence.
The named 285,923,733-byte registry blob is fetched directly in that guest: its complete SHA-256
matches `8203887b604f75d2e85df1b0682e7298d1dd26ca2a584940d8115ed5389a3421`, and
Python's gzip-tar reader traverses all 227 members. A diagnostic pull of the exact published
base digest into the same retained Docker 29.1.3/containerd 2.2.1 image store then succeeds,
including extraction of that layer. The repeated failure is intermittent in the guest's
Docker pull/extraction path; these observations do not isolate its lower-level mechanism or
replace a complete passing matrix.
The failed `hello-universe` run's active wall record is archived outside the repository,
then `restoreCurrentUserGlobalWall` with the demo's exact owner, spec, reservation,
receipt, and seven managed lines returns `Right ()`. The active wall record disappears
and `.wslconfig` retains its original SHA-256. The protected run state (171 files) is
archived at `C:\Users\Matt\AppData\Local\Temp\hb-recovery-archive-20260923\failed-run-6be03db596ac.hostbootstrap`.
The only WSL registration is confirmed as `hostbootstrap-demo-vm`, GUID
`{e864ddf5-1f31-416d-9d3b-fe873f2a3ebb}`, created during fence 38 and carrying the
run's staged config and source. The previously approved operator-assisted reset
unregisters that guest; WSL reports no installed distributions. This is recovery from
a failed attempt, not a gate pass.
A fresh complete matrix against the unchanged source tree starts through the durable Windows
launcher as `phase27-retry-20260924c`. It exits 1 at the first `hello-world` bootstrap
with `0/12 passed`: Docker 29.1.3/containerd 2.2.1 fails while extracting base layer
`sha256:4da9167f168f4bb4d18535a77fa2bdbe9a9ab6124dfc557d002b63b582af71b3`
(`unpigz: ... crc32 mismatch`). The teardown again leaves protected guest ownership and
the remaining variant is refused. The failure moved to a different layer from the
prior attempt, so repeating the full matrix without changing the guest pull path is
not yet evidence of a stable substrate.
The named 887,369,571-byte registry layer downloads directly into the retained guest
with its exact SHA-256; `unpigz -t` succeeds and Python reads all 25,437 tar members.
The published blob is sound. A diagnostic switch of the retained, otherwise idle guest
from Docker 29's default containerd image store (`overlayfs`) to the supported classic
`overlay2` store permits one cold pull of the exact published base digest to finish.
After removing the diagnostic image and pruning the otherwise empty guest Docker store,
a second cold `overlay2` pull of the same digest also passes. A fresh Kind 0.33.0 /
Kubernetes 1.37.0 cluster then imports the pulled image through `kind load docker-image`;
its `sha256:5abcea513adc79b4363cd590444b39de10bc860635eb1144b1f52e3d200fa877`
image ID is present in the node's `k8s.io` store. The probe cluster is deleted.
These diagnostic passes isolate a promising store choice, but they do not establish
a complete matrix pass or an automated stable setup for each fresh guest.
The demo bootstrap now installs a WSL-only Docker daemon configuration selecting
the classic `overlay2` image store before the first published-base pull and checks
the reported driver after Docker becomes ready. The changed tree passes the
Windows core build and 2,547 core tests, demo build and 151 demo tests, and the
Python code check and 251 Python tests. The failed run's active wall record was
archived outside the repository, `restoreCurrentUserGlobalWall` returned
`Right ()`, and `.wslconfig` regained its original SHA-256
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.
Its 34 protected records were moved to
`C:\Users\Matt\AppData\Local\Temp\hb-recovery-archive-20260923\failed-run-6e15a374616c.hostbootstrap`.
The sole WSL registration was independently checked as `hostbootstrap-demo-vm`,
GUID `{8a808235-cc0a-4f6b-984f-517b1b9e9948}`; the approved operator-assisted
reset unregistered it and left zero WSL registrations. A fresh live gate is still owed.
The first new WSL guest on the changed tree was created under wall fence 40;
its pristine bootstrap installed `/etc/docker/daemon.json` and reported
`pristine-bootstrap: WSL2 Docker image store is overlay2` before starting the
published CPU/amd64 base pull. This is an in-progress phase-24 live run, not
terminal Windows acceptance evidence.
The pull finishes with published digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`,
and build #3 starts. Its in-image `check-code` stops on Fourmolu's guarded-case
layout for the new driver check. The source is formatted to Fourmolu's exact
suggestion and the base image's Fourmolu check passes against the host tree.
The incomplete image prevents `project down` from reversing the failed up.
The active wall record and 35 protected production records are archived outside
the repository; `restoreCurrentUserGlobalWall` returns `Right ()`, and
`.wslconfig` matches its original SHA-256. The sole WSL registration is
independently checked as `hostbootstrap-demo-vm`, GUID
`{79471a9c-7c16-4805-94d0-9c87c511235c}`, with this run's staged source
and Docker configuration, then the approved reset unregisters it and leaves
zero registrations. The formatted tree still owes a fresh complete live run.
The phase-24 full Windows run against the formatted source reaches both
`hello-world` generations and passes their five checks, then fails at the
first fresh `hello-universe` base pull with `5/12 passed`. Docker 29.1.3
reports classic `overlay2` but ends the pull with `layers from manifest don't
match image configuration` after downloading all published layers. The
retained guest's diagnostic retry of that exact tag succeeds and reports
digest `sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`.
Moby's pull implementation raises this error when unpacked layer DiffIDs
disagree with the image config. The repeat success leaves the lower-level
cause unproven; a complete passing matrix and ownership audit remain owed.
In the retained guest, two cold pulls of the exact published digest then pass
with `max-concurrent-downloads=1` under `overlay2`. The source WSL2 daemon
configuration now applies that setting before the first pull, and the guest
published-base pull has at most three attempts. This is a bounded mitigation;
the source of the intermittent DiffID mismatch remains unproven. The revised
Haskell source builds with `-Werror` and passes Fourmolu; complete gate
validation is pending.
The next fresh production guest at wall fence 45 supplies a stronger check:
its first serialized published-base pull again fails with the same
layer/configuration mismatch, while the second attempt succeeds at the
expected repository digest and reaches the derived build. Serial downloads
alone therefore do not prevent the failure on this host; the bounded retry
recovers this occurrence. The live run and full matrix still need terminal
results.
That production `project up` exits 0 after build #3 verifies the exported
runtime and Kind imports the derived image. `project down` and
`project destroy` both exit 0; the post-production audit shows no WSL
registration, active wall or mode, or hostbootstrap process, and the original
`.wslconfig` hash is restored. The full Windows Harness matrix is now running
against the same source and remains the acceptance gate.
That matrix exits 1 with `4/12 passed`. Its first `hello-world` generation
passes its assertions and cleans up. The second reaches build #3 after the
first published-base pull fails and the second succeeds at the expected digest.
Its same-run restart then fails because `kind load docker-image
hostbootstrap-demo:local --name hostbootstrap-demo-test-run-81e58c02e998`
exits 1 in `project:push-image`. The retained lifecycle child record gives
this command as the first failure; the parent only reports a terminal callback
failure after acknowledgement. Detailed Kind stderr is absent, leaving the
lower-level import cause unproven. Failed-Up unwind leaves protected ownership,
so later cases refuse. The guest is unregistered, the WSL wall and original
`.wslconfig` are restored, and 240 run-state files are archived outside the
repository. The WSL image import now has three bounded attempts and emits
captured output on stderr to preserve diagnostics on the next run; complete
gate validation remains owed.
The next production attempt at WSL wall fence 48 exits before Docker during
GHCup's pinned GHC 9.12.4 installation. The installer logs stop while
`gmake install` copies libraries without a reported make error; the retained
guest has ample disk and memory, and its kernel log contains no OOM event.
Hyper-V Worker Admin records a guest-reported CPU Machine Check Exception
and fatal local machine-check kernel panic at 07:07 local time. The approved
reset archives its wall, 22 protected records, and generated config outside
the repository; wall restoration succeeds and the verified WSL GUID is
unregistered. The next fresh production attempt at fence 49 fails at the
same GHCup step. Its extracted GHC profiling archive is 595,591,168 bytes,
but the matching member in the verified download is 617,432,916 bytes;
`ranlib` fails on the extracted copy with `State.p_o: file truncated` and
passes on the complete tar member. Hyper-V records more guest-reported
machine-check panics at 07:18, 07:20, and 07:25, including during a direct
diagnostic extraction. Neither attempt reaches the Kind change. The deeper
physical or virtualization fault is unidentified; this host cannot supply
reliable live gate evidence until its WSL guest stops panicking. The approved
reset archived the fence-49 wall record, 22 protected-state files, and
generated config outside the repository. Wall restoration returned `Right ()`,
the verified sole guest GUID `{9c5cb108-819c-4992-85bb-83a7e81090ff}` was
unregistered, zero WSL registrations remain, and `.wslconfig` retains its
original SHA-256
`2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`.
All four Hyper-V fatal events carry the same machine-check status word
`b200000080060001`; the Windows System log has no WHEA-Logger event in the
same two-day window. This host runs WSL 2.7.10.0, kernel 6.18.33.2-2, and
Windows build 26200.9457. A [Microsoft WSL issue](https://github.com/microsoft/WSL/issues/41649)
reports the same guest status word on another host across later WSL and kernel
versions. That report does not establish this host's underlying cause or a fix.
The saved Windows Resource-Exhaustion-Detector events coincide with all four
panics: system commit is 63.62–63.76 GiB against a 63.87 GiB limit, with
the attached Windows `psmux` client `tmux.exe` accounting for 44.24–45.77
GiB. A later fence-50 Production retry outside that client's process tree
passes the previously failing GHC install and reaches Docker build #3 with
no new machine-check event. The live `psmux` client still hosts this Codex
session and grows from 0.07 to 1.67 GiB during the retry; the attempt is
stopped before Windows commit reaches its 23.347 GiB limit. The wall and
35 protected files are archived, wall restoration returns `Right ()`, and
the verified sole guest GUID `{41d9da26-9ecd-412f-9c64-9183a67a1d6d}`
is unregistered. The result does not replace the complete Windows matrix.
After resetting `tmux`, a fresh fence-51 Production retry again passes GHC
installation and reaches Docker build #3 on `overlay2` with the published
CPU/amd64 base at the expected digest. No Hyper-V machine-check or Windows
resource-exhaustion event occurs. The image's `check-code` step exits 1 because
GHC segfaults while building `test:hostbootstrap-core-test`; guest `dmesg`
identifies a `ghc_worker` general protection fault in the GHC 9.12.4 shared
library. Windows commit last measures 18.011 of 19.745 GiB and guest memory
afterward has 9.1 GiB available, with no OOM kill. This compiler failure is
not a reproduced WSL kernel panic, and its underlying cause is undetermined.
Normal `project down` and `project destroy` cannot finish the incomplete image
and reverse-root snapshot. The 22 protected files, generated config, and wall
record are archived outside the repository with matching hashes; the wall is
restored and the verified sole WSL guest GUID
`{fdafab47-5988-4be8-9038-4724a34ea5c0}` is unregistered. Zero guests and
no active wall remain; `.wslconfig` matches its original SHA-256. The complete
Windows matrix is still owed.

On 2026-10-16, the fresh native Windows/CUDA matrix exits 0 with `10/10 passed`: all five cases
(`pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and `durable-readback`) pass
for both `hello-world` and `hello-universe`. The repository Python bootstrapper runs
`poetry run hostbootstrap run --project-root demo test run all` through the WMI durable runner,
label `phase24-matrix-20261015`, PID 31600, from `2026-10-15T21:46:23.5140587Z` to
`2026-10-16T00:53:07.2073503Z`: 11,203.69 seconds, or 3 hours 6 minutes 43.69 seconds. Its
read-only terminal ownership and WSL wall audit passes at 00:55:51 UTC.

The host is `DESKTOP-R6BTBVS`, native x86_64 Windows 11 Home 10.0.26300.9457, with an AMD Ryzen 7
5700G, 63.87 GiB visible memory, RTX 3090 driver 617.42, and native CUDA 13.3. `doctor` classifies
it as `windows-gpu (amd64)`. The toolchain is GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1,
repository-venv Python 3.14.7, and WSL 2.7.10.0. Before the live sequence, the complete native
Windows static gate passes: 2,547 core cases, 159 demo cases including eight new protected-state
observer regressions, all 251 Python tests, and the Python code check (`ruff`, Black, and mypy).
The durable `test init`, label `phase27-init-20261015`, exits 0 at 2026-10-15 20:22:24 UTC after
about 26 minutes 56 seconds of cold dependency and executable builds. The source-built sibling
executable measures SHA-256
`b0a46ea3e9090221811bc925e0e280c365b34845032210d763f2868e90d1458f`.

This visit first recovers the historical failed run's fence-61 wall through the production
`restoreCurrentUserGlobalWall` entry point, invoked against the built current core with the demo's
exact owner/spec/reservation/receipt and managed body. It clears the active record and retained
origin pathname while preserving the monotonic fence and restoring both original bytes and Windows
file identity. The retained 2026-09-30 inspection transcript records the older
`phase24-integrity-redir-matrix-20260925` result as exit 1 and `9/12 passed`, with a GHC 9.12.4 panic
and SIGSEGV during `hello-universe` recreation at fence 61. Its original external output and exit
files are unavailable, so that is recovered historical failure evidence. Removal provenance for its
absent demo run store remains unavailable, and no closed-lease audit of that historical run is claimed.
The worked-demo phase's protected-state observer correction passes the static gate before this fresh
acceptance; no WSL registration or active wall remains before Production starts.

The fresh Production `project up`, launched durably as `phase24-production-up-20261015`, exits 0
at 2026-10-15 21:19:07.880 UTC after approximately 47 minutes 42 seconds. Its derived image ID is
`sha256:b6c94394b6d0efc4ee9e21e5733275f15be2262be6d4e158837c6127a1a0225f`, and all three
deployments report 1/1 ready. Direct host requests through the observed web relay at
`http://127.0.0.1:32769` return `3.75` for `phase27-cuda-observe` (`1.5 + 2.25`) and
`16777216` for `phase27-cuda-precision` (`16777216 + 1`). Both responses identify backend
`windows-gpu` and artifact `fc76cd884d2539b8`.

Native process observation finds daemon PID 11280 running
`demo/.build/accelerator-daemon/hostbootstrap-demo.exe` and its child PID 23200 running
`demo/.build/accelerator/windows-gpu/fc76cd884d2539b8/accelerator-worker.exe`;
`nvidia-smi` also lists worker PID 23200. The worker executable measures SHA-256
`12dddf385e9b20e805c4466b10c6b1aa6a0a618ae9d184f62c540faa45a953df`. The daemon's established
connection is `127.0.0.1:52564` to `127.0.0.1:32771`. The exact Docker relay
`hostbootstrap-exposure-f711f2f057711fac5cd1128de8bf0948`, identity
`1328772a4c1d4698077f2dccdcd323247075d83aeee43d9de95a8eafa4f0bacd`, maps its accelerator
listener 20003 to `hostbootstrap-demo-control-plane:30081` and publishes it only at
`127.0.0.1:32771`; its web listener 20001 targets the same node's port 30080 and publishes at
`127.0.0.1:32769`. These observations establish the Production host-native CUDA worker and
loopback exposure.

The supported Production `project down`, launched at 2026-10-15 21:44:07.533 UTC, exits 0 at
21:44:23.240 UTC after 15.707 seconds. `project destroy` then exits 0 at 21:45:10.833 UTC. After
Destroy, the generated Production config is hash-verified and removed according to the runbook's
operator sequence before the Harness starts. The 21:46:02 UTC Production terminal audit passes:
the sole lease is `closed` at record version 5 and epoch 3, while its historical profile remains
`consumed` at record version 2, epoch 1, and lease-version field 1. No ephemeral ownership, generated
config, live accelerator process, WSL registration, or active wall remains; `.test_data` is empty,
Production `.data` is preserved, and fence 62 is retained with the original wall bytes and file identity.

The host-only image observer verifies that the expected and received public web manifests match and
that each directory's SHA-256 digest matches that manifest, without issues. The complete Harness
runs use four fresh guest generations and four derived images:

| Variant | Run | Generation | Wall fence | WSL GUID | Image | Public web manifest | First observed UTC |
|---|---|---|---|---|---|---|---|
| `hello-world` | `run-6b565ce5808` | 1 | 63 | `{c98af45f-7a97-4bfb-b2a6-5a6254e52a8d}` | `sha256:cb897da5442f89b4d45d9ac028e6bf265a4414cfa66f01aebdf51e6b8759eff1` | `c85786891f529f9cd68481cc2f84fdb2fbfcb3f2cba214b7766122ea9ee6a38c` | `2026-10-15T22:32:48.056Z` |
| `hello-world` | `run-6b565ce5808` | 2 | 64 | `{d113accb-f472-49cd-a85c-ee982461d5ab}` | `sha256:0bf2239bf5dbe15736c82cd75ed5fc94f6fc35d54c0789dc9403b984bd659294` | `5b631345bb0ef437f201954a9a4e30abc11578e1ef00dcd72623596fcad7c3b6` | `2026-10-15T23:19:31.672Z` |
| `hello-universe` | `run-bcec61e1608` | 1 | 65 | `{b7955e79-55ea-46e9-9e16-9700c92cd8ea}` | `sha256:232d438c24a5d89ac555291117cc5d7022af79b4695c01b333c10a813de45501` | `ce4d14d79c344c05807557398886d2757029500bf39f33783d075ad344ee31ad` | `2026-10-16T00:05:53.415Z` |
| `hello-universe` | `run-bcec61e1608` | 2 | 66 | `{5c16edd9-5b5d-453f-9d33-d98db04338c1}` | `sha256:473c3a84b5163084780c1e96b9ded9300342dc68bca3cc068066dc812bce1e7a` | `1f643329131f5c26edcda491211f835ccc55324e4eea471d8f853183d36545a1` | `2026-10-16T00:52:55.070Z` |

Both variants perform the engine-owned same-run destroy/recreate before their durable readback.
The host observes the second `hello-world` guest at fence 64 at 22:33:35.822 UTC, its Ready native
daemon PID 17912 at 23:19:44 UTC, and then teardown and wall restoration. The first `hello-universe`
guest is observed at fence 65 at 23:20:14.528 UTC, its native bootstrap finishes at 23:41:41 UTC,
and Docker reports ready with `overlay2` at 23:42:35 UTC. Its Ready native daemon PID 6516 and open
assertions are observed at 2026-10-16 00:06:02.761 UTC. Both observed Harness daemons use
`ws://127.0.0.1:32771/api/accelerator/daemon`.

The `hello-universe` same-run destroy/recreate restores the wall, then acquires fence 66 at
2026-10-16 00:06:43.855 UTC. Its final fresh GUID is first observed at 00:07:24.795 UTC; native
bootstrap has completed and Docker reports ready with `overlay2` at 00:29:15.932 UTC. Every fresh
generation's published-base pull reports the same actual digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`:

| Variant | Generation | Wall fence | Base pull observed UTC |
|---|---|---|---|
| `hello-world` | 1 | 63 | `2026-10-15T22:11:19.668Z` |
| `hello-world` | 2 | 64 | `2026-10-15T22:58:16.831Z` |
| `hello-universe` | 1 | 65 | `2026-10-15T23:44:26.324Z` |
| `hello-universe` | 2 | 66 | `2026-10-16T00:31:09.481Z` |

The final image is captured at 00:52:55.070 UTC. At 00:53:07.131 UTC, host observation confirms
final deletion and wall restoration, no WSL registration or active wall record, and retained fence 66.
The wrapper then reports the complete `10/10` pass and exit 0 at 00:53:07.2073503 UTC.

The 00:55:51 UTC terminal audit reads these exact retained lease and profile facts:

| Kind | Run | Lease state / record version / epoch | Profile state / record version / epoch / lease-version field |
|---|---|---|---|
| Production | `production` | `closed` / 5 / 3 | `consumed` / 2 / 1 / 1 |
| Harness | `run-6b565ce5808` | `closed` / 6 / 7 | `available` / 3 / 6 / 4 |
| Harness | `run-bcec61e1608` | `closed` / 6 / 11 | `available` / 3 / 10 / 4 |

The external read-only helper's 00:53:32 UTC observation initially reports four false profile
comparisons: it assumed the profile epoch matched the final closed lease and its lease-version field
preceded the final record by one. Source review independently confirms
that the command's `withFreshHarnessDestroyInvocation` advances the broker epoch and lease once
without reinitializing the profile, then `finalizeHarnessClose` advances the lease again. For this
fresh serial matrix, the verified relationships are `profile epoch + 1 == closed lease epoch` and
`profile lease-version + 2 == closed lease record version`. Correcting those external helper
assertions makes the audit pass; no project source or protected record is changed, and no matrix
rerun is needed. Production retains its original consumed profile. The external helper observes
state without probing protected-entry exclusivity; the Harness executes its supported protected-state
teardown observer.

No project mode, generated-config, or data-root origin record remains. The generated project config,
daemon PID, and current protected daemon owner are absent; no host daemon or native worker remains.
The operator test config is unchanged at SHA-256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`; `.test_data` is empty and
Production `.data` is preserved. HKCU's WSL registration inventory is empty. The wall has no active
record and retains monotonic fence 66; `.wslconfig` has its original SHA-256
`2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694` and Windows file ID
`0x00000000000000000061000000023bde`. Supported `wsl.exe --shutdown` exits 0 after wall restoration
and the empty registration inventory have been verified. The utility VM is already off at the
corrected 00:55:51 UTC audit, with no `vmmemWSL` process. The phase's complete 845-file
covers digest is remeasured after the gate and remains unchanged at
`cb608a90e5ca585ddd064cfc69010e02283159d44c926bda4b273a8bb8f3e10b`.

After phase 24 closes and this evidence is recorded, the native documentation check
`cabal test hostbootstrap-core-test --test-show-details=direct --test-options="-p DocValidatorSpec"`
from `core/` passes 11/11 in 5.69 seconds. It validates status harmony, complete gate evidence,
and the current covered-source digests. `git diff --check` passes, and changed text files retain LF.

The exact 2026-10-16 gate-evidence row is retained for the source that run exercised.
The later formatter update does not restamp this result:

- 2026-10-16 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 Home 10.0.26300.9457,
AMD Ryzen 7 5700G, 63.87 GiB, RTX 3090 driver 617.42, CUDA 13.3, WSL 2.7.10.0,
GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1, repository-venv Python 3.14.7 ; repository Python bootstrapper
`poetry run hostbootstrap run --project-root demo test run all`, launched through the WMI durable
runner, followed by the terminal ownership and WSL wall audit and `wsl.exe --shutdown` ; pass ;
covers cb608a90e5ca585ddd064cfc69010e02283159d44c926bda4b273a8bb8f3e10b

#### Remaining Work

None.

### Sprint 27.6: Revalidate Windows acceptance against shared source [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: windows
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Re-establish native Windows/WSL2 acceptance after shared Haskell source formatting and assertion-frame
durable-root projection, provider reachability admission, and core/demo regression changes.

#### Deliverables

- The repository Python bootstrapper's complete configured matrix passes on native Windows.
- The terminal ownership and WSL wall audit confirms released run state and restored ambient state.
- Dated gate evidence records the actual native run and a fresh measurement over this phase's evidence paths.

#### Validation

On 2026-10-16, the base-publication quality preflight selects compatible Fourmolu 0.19.0.1 and
HLint 3.10 for minimal source corrections. These include formatter findings in shared sources and
specs, a demo `valueLines` spelling accepted by Fourmolu 0.19.0.1 and 0.21, Windows-only guards for the
`EmptyCase` and `OverloadedStrings` pragmas used by those branches. This phase was
reopened before those covered inputs changed. No Windows run against the changed tree is claimed.
Sprint 27.5 preserves the complete preceding pass, terminal audit, and original 845-file source scope
and digest.

On 2026-10-16, the shared assertion-frame durable-root adoption changes covered demo source.
The 25-root, 845-file scope now measures
`08d45edf2e1b616834a61ccf12783a8f04c84589c9a40f4f20eeff2f9099ee96`.
This measurement establishes no native Windows gate pass.

On 2026-10-20, Sprint 24.46 adds shared provider reachability admission: an absent provider returns
a failed teardown outcome before any start effect or guest descent. The covered core and demo
regression sources also change. The 25-root, 845-file scope now measures
`ecf6b4522ebbd983f3f702fe6b95e14c7d1c3843811b7fb0c781b3a5a094d0e7`.
This is a source measurement, with no new native Windows/WSL2 gate pass. The available Apple M1 Max
host cannot supply this phase's native Windows/WSL2 gate. Earlier dated runs retain their original
scopes, measurements, and outcomes.

On 2026-10-21, the native Linux/NVIDIA visit on `matt-caledon-desktop` completes the
preceding NVIDIA acceptance and the native x86_64 Linux host static gate. Execution reaches
this phase in numerical order and stops: the available session is native Linux with an RTX 3090,
and cannot exercise the native Windows/WSL2 matrix or global WSL wall. No native Windows pass
or refreshed gate evidence is claimed. The unchanged 25-root, 845-file scope remeasures to
`ecf6b4522ebbd983f3f702fe6b95e14c7d1c3843811b7fb0c781b3a5a094d0e7`.
Sprint 27.6 remains Active for its declared native Windows gate.

On 2026-10-22, native Windows host `DESKTOP-R6BTBVS` completes the declared acceptance.
`poetry run hostbootstrap doctor` reports `windows-gpu (amd64)`; the RTX 3090 is available
and the initial demo state has no WSL registration, active wall record, Production `.data`,
or Harness `.test_data`. The baseline wall fence is 66. Approximately 225 GiB is free
against the operator test config's 80-GiB storage budget; it also declares 6 CPUs and
10 GiB memory. Repository Python code checks and all 251 Python cases pass as preflight.

The durable `phase27-init-20261022` native demo build and `test init` exit 0 at
14:08:32 UTC, following the 13:47:07 UTC launch. The source-built executable measures
SHA-256 `a65e3c244a3e57c904f115e38a654d8ce93c56d66971edee3ebb10cd6010801e`.
The complete repository-bootstrapper matrix starts at 14:09:26.662849 UTC as
`phase27-matrix-20261022`, PID 11272 parented by `WmiPrvSE.exe`, outside the agent process
tree. It reports `10/10 passed` and exits 0 at 18:12:35.2032018 UTC, after approximately
14,588.54 seconds (4 hours 3 minutes 9 seconds). Both `hello-world` and `hello-universe`
pass `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and
`durable-readback`. Each variant completes its engine-owned same-run destroy/recreate and
terminal destroy. No gate restart or source repair is needed.

The host-only observer verifies four distinct image/public-web revisions, with matching
expected and received manifests and directory SHA-256 digests, and zero verification issues:

| Variant | Run | Generation | Wall fence | WSL GUID | Image | Public web manifest | First observed UTC |
|---|---|---|---|---|---|---|---|
| `hello-world` | `run-2d77e1e156f0` | 1 | 67 | `{95644321-66aa-4a00-9fe3-57bd3f53290c}` | `sha256:0d12e00e26770d12fe1acca2c920aff781c8cbfcf1de052fab93352c57394136` | `8084b8642b8bc407795b40cea18f2995855f42d16f0fc116f6f63cb751be54d0` | `2026-10-22T15:06:25.551Z` |
| `hello-world` | `run-2d77e1e156f0` | 2 | 68 | `{bb86ce2c-75fe-477c-9f75-b542b0db5e3c}` | `sha256:4106cbd44842b8083bdbb3beb155cff62eb38da7ea27e7a1370eb7f20bd86ae1` | `8a658c3e92e00d1f7dbd93495fc39a76c289a06a96922947c2302ab87bc868c7` | `2026-10-22T16:15:05.268Z` |
| `hello-universe` | `run-345533167db4` | 1 | 69 | `{04f26b2f-2f51-4386-87c7-ca000cedc665}` | `sha256:84d6127d1bf0bb5c91e63fdb8d2d10c69a5e3e0df8420a7954dc90feb27897c3` | `2c18c32105162e6c5c4b82390dbd4637f39cde3e7664c3a943ca89aecc51702c` | `2026-10-22T17:14:54.769Z` |
| `hello-universe` | `run-345533167db4` | 2 | 70 | `{25a24444-e45f-46f9-acc3-613b67ba4eaa}` | `sha256:6062fbe1b99f7e8dd03adb36d1b978cbf4e865858c299fd49a5e39e646d466d5` | `f61b786e1f09048492eafe51d7565a400834172e4040ced9f58f31052018da25` | `2026-10-22T18:12:19.793Z` |

Every guest uses Docker's `overlay2` image store and pulls the published CPU/amd64 base
at `sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`.
The fourth native bootstrap is observed complete by 17:47:47 UTC, Docker is ready by
17:48:52 UTC, and its base pull finishes by 17:50:51 UTC. Its archive integrity and
runtime/config/public-key/web-bundle export verification pass by 18:04:39 UTC.

Both variants directly observe their native CUDA worker through Win32 process inventory
and `nvidia-smi`: `hello-world` worker PID 29640, child of daemon 23016, at
15:07:07.697 UTC; `hello-universe` worker PID 29168, child of daemon 16488, at
17:15:13.029 UTC. Both use
`demo/.build/accelerator/windows-gpu/fc76cd884d2539b8/accelerator-worker.exe`.
All four native daemons are observed: PIDs 23016, 13632, 16488, and 23628, in generation
order. Each connects through the resolved local-only exposure
`ws://127.0.0.1:32771/api/accelerator/daemon`; the final established connection is
`127.0.0.1:55644` to `127.0.0.1:32771`. No worker observation is claimed for the two
restart generations.

The 18:12:51 UTC read-only terminal ownership and WSL wall audit passes with these exact
retained records:

| Kind | Run | Lease state / record version / epoch | Profile state / record version / epoch / lease-version field |
|---|---|---|---|
| Harness | `run-2d77e1e156f0` | `closed` / 6 / 4 | `available` / 3 / 3 / 4 |
| Harness | `run-345533167db4` | `closed` / 6 / 8 | `available` / 3 / 7 / 4 |

No mode, generated-config, or data-root ownership record remains. The generated project
config, daemon PID, and protected daemon owner are absent, and no native daemon or worker
process remains. The operator test config retains SHA-256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The `.test_data` parent exists and is empty; Production `.data` remains absent. The
external helper reads records without probing protected-entry exclusivity; the Harness
runs its supported teardown assertions.

HKCU's WSL registration inventory is empty. There is no active wall record or managed wall
sidecar; the monotonic fence is 70, exactly four acquisitions beyond baseline 66.
The restored `.wslconfig` retains its original SHA-256
`2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`
and Windows file ID `0x00000000000000000061000000023bde`. Only after confirming that
restoration and empty registration inventory, supported `wsl.exe --shutdown` exits 0 at
18:12:58–18:13:01 UTC. No `vmmemWSL` process remains, and 55.2 GiB of physical memory is free.

The post-gate 18:13:01 UTC measurement covers all 25 roots and 845 files at
`ecf6b4522ebbd983f3f702fe6b95e14c7d1c3843811b7fb0c781b3a5a094d0e7`, matching the
pre-gate and 16:41 UTC measurements. No covered source changes during the run. This closes
Sprint 27.6 and the Windows acceptance before native Windows host-static validation begins.

After recording the complete evidence and Done statuses, native
`cabal test hostbootstrap-core-test --test-options="--pattern DocValidator" --test-show-details=direct`
from `core/` passes 11/11 in 6.62 seconds. This verifies documentation, status harmony,
complete gate evidence, and covered-source currency before phase 28 begins.

#### Remaining Work

None.

## Remaining Work

None.

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
