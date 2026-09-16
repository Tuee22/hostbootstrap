# Phase 25 — Apple Silicon substrate

**Status**: Done
**Depends on**: Phase 24 (the worked demo)
**Substrates**: apple-silicon
**Gate**: repository Python-bootstrapper `poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed` on an Apple Silicon host, plus a focused live exact-plan direct-Colima adapter lane
**Gate kind**: deferred
**Gate evidence**: 2026-09-16 ; `MacBookPro`, arm64 macOS 26.6.2 (build 25G83), Apple M1 Max,
Lima 2.1.2, Colima 0.10.3, GHC 9.12.4, Cabal 3.16.1.0, Python 3.14.3, Poetry 2.3.2 ;
repository Python bootstrapper `poetry run hostbootstrap run --project-root demo test run all`
from the repository root, plus `HOSTBOOTSTRAP_COLIMA_LIVE=1 cabal test hostbootstrap-core-test --test-options='--pattern Colima' --test-show-details=direct`
from `core/` ; pass ; covers d0f43dfbf6dc47459720e424ceb7ca73855905990313b028c10cc47c9bdd3ca2
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/AppleMetal.hs` `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs` `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima` `core/hostbootstrap-core/src/HostBootstrap/Ensure/Lima.hs` `core/hostbootstrap-core/src/HostBootstrap/Lima.hs` `core/hostbootstrap-core/internal/colima-backend` `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider` `core/hostbootstrap-core/internal/effect`

> **Purpose**: Add the Apple-only Metal accelerator realization, exercise Lima/Colima as the Apple-host
> realization of universal `linux-cpu`, and confirm the additional Apple behavior.

## Phase Objective

This is an **acceptance phase** (§ II). It does not create a second CPU substrate: it confirms the universal
`linux-cpu` contract through the Apple provider and accepts the additional Metal and host-native behavior.
Nothing depends on that Apple-only dimension.

It has two jobs: supply the accelerator realization only this substrate has, and confirm on real hardware
the lower Phase 15 (host providers and the self-reference lift) Lima provider and every behavior the
baseline lane cannot exercise — because a run on one architecture and provider validates only that lane.

## What this phase confirms

Every baseline phase closes on its own gate. The behaviours below are the ones that need *this* substrate, and
listing them here is what keeps a static closure from silently dropping live coverage:

- the sealed invocation-shape boundary, on the one lane where a host-resident daemon must survive its launcher;
- the Lima provider's full lifecycle: provision at the declared budget, reboot-to-ready, the durable share mount,
  the guest alias, stop on `down`, and VM deletion on terminal `destroy`;
- the exact plan-owned direct-Colima profile/wall adapter against the native Colima surface, including
  same-name conflict refusal and non-activation of the shared `default` profile;
- the guest-alias ownership clauses executing on a BSD host userland, with the locking primitive and `stat`
  dialect taken from the discovery probe rather than assumed;
- host-native accelerator placement behind a local-only node port, rather than an in-cluster service address;
- the harness ownership bracket's full release path against a real provider, from a pristine host;
- the bounded process runner's macOS branch, whose working-directory handling both backends now share.
  A gate host that is not Apple never takes that branch, so one answer where there were two is
  confirmed here rather than asserted by the phase that unified it.

## What one Apple visit records

This phase declares exactly one substrate beyond the baseline (§ II), and its gate is the Apple hardware
run above. But a hardware set is visited once (§ JJ), and Apple Silicon is the only hardware that carries
three of the plan's cells at the same time:

| Cell | Owned by |
|---|---|
| Apple Silicon / Metal substrate acceptance | this phase |
| macOS gate host, host static gate | [phase 28](phase-28-host-portability-acceptance.md) |
| arm64 Linux gate host, host static gate | [phase 28](phase-28-host-portability-acceptance.md) |

An Apple visit therefore records all three before it ends: this phase's live matrix and Colima lane, the
complete host static gate natively on macOS, and the same gate inside an arm64 Linux VM or container. None
of the three is this phase's closure condition — § C forbids that, and phase 28 owns the two gate-host
rows — but collecting them in one sitting is what stops the arm64 Linux cell from later demanding a second
trip to the same machine.

## Sprints

### Sprint 25.1: Lima provider acceptance [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`,
`core/hostbootstrap-core/test/LimaSpec.hs`
**Substrates**: apple-silicon
**Docs to update**: `documents/engineering/lima.md`

#### Objective

Confirm the Phase 15 (host providers and the self-reference lift) Lima lifecycle realization against its
Apple host surface.

#### Deliverables

- Provisioning applies the project's declared sizing; the VM is created at budget rather than at a default.
- Reboot-to-ready observes readiness; the durable host-path share is mounted through the per-substrate primitive.
- `down` stops the VM and `destroy` deletes it; terminal Harness cleanup drives the destroy path, so a completed
  run does not leave an instance behind.
- The guest alias uses the shared clause-holding backend, with its userland facts read off the probe.
- The target record and inner `limactl shell` renderer come from the lower lift-context phase, while the
  provider lifecycle builders come from the host-providers phase; this sprint confirms rather than
  redefines either boundary.

#### Validation

`LimaSpec` covers the argument shapes and each operation. Dated live evidence: the Apple/Lima lifecycle lane
reported `10/10`, exercising `ensure lima`, `vm up` at budget, the durable share, the guest alias, and terminal
VM deletion.

#### Remaining Work

None.

### Sprint 25.2: The Metal accelerator realization [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/AppleMetal.hs`,
`demo/src/HostBootstrapDemo/Accelerator/`
**Substrates**: apple-silicon
**Docs to update**: `documents/engineering/accelerator_daemon.md`

#### Objective

Build and run the Swift/Metal worker.

#### Deliverables

- `ensure apple-metal` reconciles the Swift/Metal toolchain and is a no-op when present.
- The worker is built with the host toolchain and reached over the private listener with a CBOR round trip.
- The daemon is host-resident and singleton; its launch uses the sealed invocation-shape boundary so a
  pre-readiness failure writes its cause somewhere readable rather than to a closed descriptor.

#### Validation

Dated live evidence: `e2e-tabs` passed on both variants on Apple Silicon, asserting the daemon-returned sum,
backend, and artifact hash through the browser — so Metal ensure, the worker build, the WebSocket connect, and
the CBOR round trip are proved live rather than merely started.

#### Remaining Work

None.

### Sprint 25.3: Apple Silicon acceptance [Done]

**Status**: Done
**Implementation**: the whole tree; the focused direct-Colima lane is in
`core/hostbootstrap-core/test/ColimaSpec.hs`, with its native resolver and exact namespace ownership in
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Native.hs`
and `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`
**Substrates**: apple-silicon
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Confirm the current build on this substrate.

#### Deliverables

- From a pristine host — no durable root, no build directory, no VM instance, no protected store — run
  `test init` then `hostbootstrap run -- test run all` and record `10/10 passed`.
- Audit the end state: both run leases closed, no mode, config, or data-root record left, the generated sibling
  config gone, the per-run data directory empty with its parent preserved, the durable root intact, and the VM
  removed.
- Record the observed duration against a 60–80 minute envelope over four bring-ups and four destroys.
- Run the focused exact-plan direct-Colima adapter lane against native Colima and record its profile derivation,
  conflict-refusal, `default`-profile non-activation, and cleanup results.
- The in-container `check-code` runs on each bring-up, which is the only place `fourmolu` and `hlint` execute.

#### Validation

On 2026-08-26/27, a pristine run on macOS 26.5 (build 25F71), arm64, GHC 9.12.4, Cabal
3.16.1.0, Lima 2.1.2, and Colima 0.10.3 completed in about 79 minutes and reported `10/10 passed`.
`test init` began with no `.build`, protected store, generated sibling config, run-data parent, or Lima
instance. The matrix used Harness runs `run-3f4b674921968` and `run-3f6cfe2de3ad0`; all four fresh guest
generations pulled base digest
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, completed the
in-container code check/export verification, and produced derived image digests
`sha256:90395b4f7b0b0a21ebca2907f3e8caed49265667c1e2864ea2580cc9cc7a40d9`,
`sha256:bcaf9967c427900354364f134b6ef86814712e750c5e771d0a7ec86119dd3018`,
`sha256:e78a9ea521743bf3f60f3611ceb8c61c5fdc77e263bf29c6a762e67346ddf7fb`, and
`sha256:4cf7708ae600aebf29410fcc706609d600db3b435e5147da8be9d218358bbe47`.

The terminal audit found both run leases `closed`, no project mode, generated-config, or data-root
ownership record, no generated `hostbootstrap-demo.dhall`, an empty preserved `.test_data` parent, no
live accelerator process, and no Lima instance. Both `durable-readback` rows proved the exact durable
root across the engine-owned destroy/recreate before terminal release. The ambient Docker context remained
`colima`, and the pre-existing `default` Colima profile remained running with its original 9-CPU,
48-GiB-memory, 512-GiB-disk wall.

The opt-in native direct-Colima test completed in 38.88 seconds with isolated profile `h-85bdaf`. It
derived that opaque exact-plan profile, acquired and settled it, refused a same-plan incompatible 9-CPU
re-entry as `Conflict`, never activated the shared `default` profile, and removed the exact profile,
Docker context, data, temporary/cache namespaces, and isolated home. The final warning-clean core gate
passed 2,475/2,475 in 369.23 seconds.

#### Remaining Work

None. The pristine Apple/Lima matrix, terminal ownership audit, and native exact-plan direct-Colima lane
are complete.

### Sprint 25.4: The Apple Silicon acceptance run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: apple-silicon
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Record both live acceptance lanes against the same tree on an Apple Silicon host.

#### Deliverables

- A dated run of the repository Python-bootstrapper's complete demo matrix reporting `10/10 passed`.
- A dated native exact-plan direct-Colima lane proving acquisition, conflict refusal, and cleanup.
- A terminal ownership audit and a covers digest matching the tree both lanes exercised.

#### Validation

**2026-09-09 — passed.** Both lanes ran on native arm64 macOS 26.6.2 (build 25G83), with Lima 2.1.2,
Colima 0.10.3, kind 0.31.0, GHC 9.12.4, Cabal 3.16.1.0, Python 3.14.3, and Poetry 2.3.2.

The demo began without `.build`, `.hostbootstrap`, `.test_data`, `.data`, generated sibling config,
Lima instance, or accelerator process. From the repository root,
`poetry run hostbootstrap run --project-root demo test init` built the host-native binary and wrote its
sibling test config. The Python module resolved to this checkout's `hostbootstrap/` package.

`poetry run hostbootstrap run --project-root demo test run all` reported **10/10 passed**, with exit 0,
in **6,801.62 seconds (1 hour 53 minutes 22 seconds)**, starting at 12:40:05 UTC. This exceeds the
60–80 minute planning envelope; the initial cold host-native build is additional. Both `hello-world`
(`run-26ffba3bd2610`) and `hello-universe` (`run-2731778d2db60`) passed `pristine-bootstrap`,
`web-build`, `e2e-tabs`, `registry-persistence`, and `durable-readback`. The matrix completed four fresh
Lima bring-ups and four destroys, including one same-run durable reconstruction per variant, with no
`BROKEN`, `LEAKED`, or `FAILED` row. Each image completed its in-container check-code and export
verification; both variants exercised the host Metal daemon through their end-to-end assertions.

Every fresh guest pulled published base digest
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`.
The derived image digests, in generation order, were:

| Variant | Generation | Derived image digest |
|---|---|---|
| `hello-world` | Initial | `sha256:95d4d6ca5259bf802710947c55b8294c56eab040c9dc7c3d1ccf138da8c5ff2a` |
| `hello-world` | Durable reconstruction | `sha256:40cd65ee7a98c2f61cac61c88db137d19c665578342f405443cdd7363bcec5f2` |
| `hello-universe` | Initial | `sha256:70b3a02e683f650357a170978b074fef82fb89c32b8e5a5afef3668fda95176a` |
| `hello-universe` | Durable reconstruction | `sha256:46d4e1c75198fd0f71e31f032c4334be20b95c7987bcaa47bc9d44fbe4aab271` |

The terminal audit confirmed both protected leases encode `closed` (epochs 4 and 8); no project mode,
generated-config, or data-root record remains. The generated `.build/hostbootstrap-demo.dhall` is absent;
the test config and five installed identity artifacts remain. `.test_data` is preserved and empty,
`.data` retains its initial absent state, no accelerator process or Lima instance remains, and the ambient
Docker engine has no containers. The Colima `default` (Running) and `incus` (Stopped) JSON listings and
Docker context listing are byte-identical to preflight, with `colima` still selected.

From `core/`,
`HOSTBOOTSTRAP_COLIMA_LIVE=1 cabal test hostbootstrap-core-test --ghc-options=-Werror --test-options='--pattern Colima' --test-show-details=direct`
passed **33/33** in **41.51 seconds**. The live case took 38.18 seconds, derived profile `h-c2a539`,
refused the incompatible same-name acquisition, and reported exact profile/context/data cleanup with
ambient `default` unchanged. No managed `h-*` profile remains. The 31-file covers measurement matched
before and after both lanes; the header records that digest.

The supporting native macOS static gate also passed: `cabal build all --ghc-options=-Werror` and
`cabal test all --ghc-options=-Werror --test-show-details=direct` from `core/`, with **2,497/2,497**
core cases in 391.11 seconds (401.70 seconds including component work). The provider-live component
compiled and reported its declared `Unsupported: provider-live not requested` disposition; this is no
claim of Linux provider acceptance. From the repository root, the Python code check passed and the
Python suite passed **235/235** in 1.56 seconds.

The closing `DocValidatorSpec` gate passed **5/5**, checking governed-document conformance, phase/index
status harmony, and the recorded evidence against the tree. `git diff --check` passed.

#### Remaining Work

None. Both live lanes, the terminal audit, and the matching evidence measurement are complete.

### Sprint 25.5: The Apple Silicon acceptance against the current tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: apple-silicon
**Docs to update**: `documents/engineering/testing.md`

#### Objective

This phase's evidence covers the host-portable tree, so ordinary source change expires its claim —
which § G names as the expected state for an acceptance phase between runs rather than as an unclosed
phase. The claim is re-established by running the gate on an Apple Silicon host, not by re-recording a digest
over a tree nothing re-tested. That visit also carries the macOS gate host and an arm64 Linux gate host.

#### Deliverables

- The phase's declared gate is re-run in full on the hardware it declares.
- A gate-evidence row records the date, the gate host, the command as run, and the result.
- The row names which program ran where two share a name, and prefers an invocation against the tree over a separately installed one.
- The covers digest is re-measured over this phase's own paths and recorded.
- Every cell this hardware can produce is recorded in the same visit, so the machine is not owed a second one.

#### Validation

On 2026-09-16, the complete declared gate passes on `MacBookPro`, native arm64 macOS 26.6.2 (build 25G83),
Apple M1 Max with 64 GiB memory, GHC 9.12.4, Cabal 3.16.1.0, Python 3.14.3, Poetry 2.3.2,
Lima 2.1.2, and Colima 0.10.3. Preflight finds no demo `.build`, `.hostbootstrap`, `.test_data`,
`.data`, Lima instance, demo process, or ambient Docker container. The ambient Docker context is
`colima`; the `default` Colima profile is Running at 9 CPUs, 32 GiB memory, and 512 GiB disk,
and the `incus` profile is Stopped at 2 CPUs, 2 GiB memory, and 100 GiB disk.

The repository Poetry environment is installed from `pyproject.toml`, and the imported Python package
resolves to this checkout. The repository bootstrapper's
`poetry run hostbootstrap run --project-root demo test init` passes in 1,147.48 seconds,
including its cold host-native build, and writes the sibling test config. Its SHA-256 is
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b` before and after the matrix.

The focused live lane passes from `core/` with
`HOSTBOOTSTRAP_COLIMA_LIVE=1 cabal test hostbootstrap-core-test --test-options='--pattern Colima' --test-show-details=direct`:
33/33 cases in 40.31 seconds (132.39 seconds including test compilation). Its native case takes
36.99 seconds, derives exact profile `h-f3b022`, refuses the incompatible same-name acquisition,
and confirms exact profile/context/data cleanup with the ambient default unchanged.

Supporting native checks pass: `cabal build all` from `core/` in 199.40 seconds,
`poetry run python -m hostbootstrap.check_code`, and
`poetry run python -m hostbootstrap.test_all` at 251/251 in 1.71 seconds. The complete
`cabal test all --test-show-details=direct` from `core/` passes 2,546/2,546 in 381.88 seconds
(391.90 seconds including component work), including the documentation validator. The provider-live
component builds and reports its declared no-request `Unsupported` result.

The repository bootstrapper's `poetry run hostbootstrap run --project-root demo test run all`
starts at 13:25:19 UTC and exits 0 with **10/10 passed** in 7,066.79 seconds (1 h 57 min 46.79 s).
Each variant passes `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and
`durable-readback`, including its same-run guest destruction and durable reconstruction.
The first guest's measured allocation matches the declared 6 CPUs, 10 GiB memory, and 80 GiB disk,
with the exact run's writable durable share. All four fresh guests pull published CPU/arm64 base
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`.
Each completes its host-native bootstrap, derived-image gate, and export verification, then starts
MinIO, the registry, the web service, and the host-native accelerator daemon.

| Variant and run | First image | Image after durable reconstruction |
|---|---|---|
| `hello-world`, `run-3efb3a560f8` | `sha256:98db091f15c7cce1e4c5cc562be119c2625a1eac0f28cda3616aa9b447562aab` | `sha256:e6fa8eb7d03f8aa138c4a439f400aa4d8dac9d761e6f92ff3c790183d7ea97a6` |
| `hello-universe`, `run-7625e8580c8` | `sha256:5f6b0d72901c0d874e448d18fe2a89e7ff3d414fd190d8c7b1d8de514867867a` | `sha256:40b846a5369a681be8b0b72a7e78fa7bdc7cf07c92502ff6b37ecd696c41ec95` |

The terminal audit at 15:23 UTC confirms both run leases Closed (epochs 4 and 8), both profiles
Available, and no run config, data-root, or mode ownership records. The sibling production config
is absent, `.test_data` is empty, and `.data` remains absent. No Lima instance or demo process
remains. The ambient Docker context, both Colima profiles and their budgets, and empty ambient
container set match preflight; the focused lane's temporary Colima profile is absent.

The post-run measurement of the 31 covered files matches the pre-run measurement and the header's
`d0f43dfbf6dc47459720e424ceb7ca73855905990313b028c10cc47c9bdd3ca2`. No covered source changes
were needed. The same visit's complete macOS and arm64 Linux host static gates, including both
Cabal workspaces, are recorded in [phase 28, Sprint 28.5](phase-28-host-portability-acceptance.md).
After closure, `cabal test hostbootstrap-core-test --test-options='--pattern DocValidatorSpec' --test-show-details=direct`
passes 11/11 in 2.77 seconds, checking status harmony, governed documentation, and the recorded
evidence against the tree. `git diff --check` passes.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — the Apple realization's place in the provider dispatch.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
- `documents/engineering/lima.md` — the Lima provider lifecycle.
- `documents/engineering/accelerator_daemon.md` — the Metal worker and host-native placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the Apple sequence, the duration envelope, and the pristine-host
  precondition.
