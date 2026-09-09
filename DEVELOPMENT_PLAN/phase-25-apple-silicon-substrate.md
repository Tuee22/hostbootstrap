# Phase 25 — Apple Silicon substrate

**Status**: Done
**Depends on**: Phase 24 (the worked demo)
**Substrates**: apple-silicon
**Gate**: live `hostbootstrap run -- test run all` reporting `10/10 passed` on an Apple Silicon host, plus a
focused live exact-plan direct-Colima adapter lane
**Gate kind**: deferred
**Gate evidence**: 2026-09-08 ; arm64 macOS 26.6.2 (build 25G83), Lima 2.1.2, Colima 0.10.3, kind 0.31.0, GHC 9.12.4, Cabal 3.16.1.0 ; Python-bootstrapper `hostbootstrap run -- test run all` plus `HOSTBOOTSTRAP_COLIMA_LIVE=1 cabal test --test-options='--pattern Colima'` ; pass ; covers fecbffb2e680eea7c487ecd619dd065891c4d3571ba7cfddedef3c335f2d7d7b
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
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated live acceptance matrix on an Apple Silicon host.

#### Deliverables

- one dated run of `hostbootstrap run -- test run all` reporting `10/10 passed`, naming its host.

#### Validation

**2026-09-08 — passed. This is the run the header row records.** Both halves ran against one tree on
arm64 macOS 26.6.2 (build 25G83) with Lima 2.1.2, Colima 0.10.3, kind 0.31.0, GHC 9.12.4 and
Cabal 3.16.1.0.

The live acceptance: `hostbootstrap run -- test run all` reported `10/10 passed` in 1 hour 51 minutes
38 seconds — both variants across `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`
and `durable-readback` — over four fresh Lima bring-ups and four terminal destroys, with no `BROKEN`,
`LEAKED` or `FAILED` row. The audited end state holds: no demo Lima instance remains,
`hostbootstrap-demo.dhall` is gone while `.test.dhall` and the five installed identity artifacts are
retained, `.test_data` is present and empty, and the ambient Colima `default` and `incus` profiles are
byte-identical to their pre-run listing.

The focused direct-Colima adapter lane, re-run the same day rather than carried forward: 33/33 in 40.96
seconds with `HOSTBOOTSTRAP_COLIMA_LIVE=1`, the live case taking 37.78 seconds and reporting
`direct-colima-live: project=hostbootstrap-core-test profile=h-202dee` then
`conflict refused; exact profile/context/data cleaned; ambient default unchanged`. No `h-*` profile
remained afterwards.

This run also matters for a reason outside this phase. Every earlier `hostbootstrap run` on this host was
driven by a pipx install dated 2026-08-05 that omitted both `-j1` and the
`--hostbootstrap-install-identity` call the current source makes unconditionally; the CLI was reinstalled
from the repository earlier the same day, so this is the first Apple acceptance matrix driven by a
bootstrapper matching the tree its digest measures.

The 2026-09-06 run below is retained as history.

Both halves of this phase's gate ran on 2026-09-06 on arm64 macOS 26.6.2 (build 25G83) with Lima 2.1.2,
Colima 0.10.3 and kind 0.31.0.

The live acceptance: `hostbootstrap run -- test run all` reported `10/10 passed` — both variants across
`pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and `durable-readback` — over four
fresh Lima bring-ups and four terminal destroys, with the Metal accelerator daemon reaching ready on the
host before assertions. The audited end state holds: no demo Lima instance remains, `.test_data` is
present and empty, no daemon is live, and the ambient Colima `default` profile is unchanged.

The focused direct-Colima adapter lane: `ColimaSpec` passed `18/18` in 42.74 seconds with
`HOSTBOOTSTRAP_COLIMA_LIVE=1`, the live case reporting
`direct-colima-live: project=hostbootstrap-core-test profile=h-542e02` and then
`conflict refused; exact profile/context/data cleaned; ambient default unchanged`. It derived the opaque
exact-plan profile, acquired and settled it, refused a same-plan incompatible acquisition, and cleaned up
without activating the shared profile.

#### Remaining Work

None.

The previous entry recorded that this phase was owed its live acceptance again, because a deduplication
pass had changed `Ensure/Colima/Ownership.hs` and `Ensure/AppleMetal.hs` inside this phase's covers set
after the 2026-09-06 matrix. That is now discharged by the 2026-09-08 run above, which re-ran **both**
halves against one tree rather than carrying the adapter lane forward from a prior day.

It is worth keeping the reason on the record: the currency rule priced a refactor that looked purely
cosmetic, and the honest response was to re-run the matrix rather than re-stamp a digest. That is the
substitution the mechanism exists to prevent, and it held.

## Remaining Work

None.

Both halves of the gate are recorded against the current tree in Sprint 25.4: the live matrix at
`10/10 passed` and the focused direct-Colima adapter lane, both dated 2026-09-08.

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
