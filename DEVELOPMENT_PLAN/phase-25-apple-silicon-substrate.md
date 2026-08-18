# Phase 25 — Apple Silicon substrate

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: apple-silicon
**Gate**: live `hostbootstrap run -- test run all` reporting `10/10 passed` on an Apple Silicon host, plus a
focused live exact-plan direct-Colima adapter lane

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

### Sprint 25.3: Apple Silicon acceptance [Active]

**Status**: Active
**Implementation**: the whole tree
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

The `10/10` report, audited end state, and focused live exact-plan direct-Colima result, recorded together with
the host, OS, architecture, compiler, provider, and duration.

#### Remaining Work

Run the complete acceptance gate after the recursive-lifecycle-command, prepared-operations, step-algebra,
authenticated-handoff, recovery, and worked-demo dependencies are closed. The run must exercise typed
frame-indexed teardown descent across the real provider boundary, terminal Harness destroy, and the focused
exact-plan direct-Colima adapter lane.

## Remaining Work

Sprint 25.3, the acceptance run itself. Sprints 25.1 and 25.2 are closed with their own dated live
evidence; what is left is the pristine-host re-run of the complete matrix against the current tree,
which is owed to Apple Silicon hardware and to nothing else.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — the Apple realization's place in the provider dispatch.

**Engineering docs to create/update:**
- `documents/engineering/lima.md` — the Lima provider lifecycle.
- `documents/engineering/accelerator_daemon.md` — the Metal worker and host-native placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the Apple sequence, the duration envelope, and the pristine-host
  precondition.
