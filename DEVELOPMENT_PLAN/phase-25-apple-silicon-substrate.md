# Phase 25 — Apple Silicon substrate

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: apple-silicon
**Gate**: live `hostbootstrap run -- test run all` reporting `10/10 passed` on an Apple Silicon host

> **Purpose**: Add the Apple realizations — the Lima provider and the Metal accelerator — and confirm the whole
> build on that substrate.

## Phase Objective

This is an **acceptance phase** (§ II). Nothing depends on it, so a machine without Apple Silicon stops at the
worked-demo phase rather than being blocked. It carries exactly one substrate beyond the baseline.

It has two jobs: supply the realizations only this substrate has, and confirm on real hardware the behaviours
the baseline lane cannot exercise — because a run on one architecture and provider validates only that lane.

## What this phase confirms

Every baseline phase closes on its own gate. The behaviours below are the ones that need *this* substrate, and
listing them here is what keeps a static closure from silently dropping live coverage:

- the sealed invocation-shape boundary, on the one lane where a host-resident daemon must survive its launcher;
- the Lima provider's full lifecycle: provision at the declared budget, reboot-to-ready, the durable share mount,
  the guest alias, and VM deletion on every teardown;
- the guest-alias ownership clauses executing on a BSD host userland, with the locking primitive and `stat`
  dialect taken from the discovery probe rather than assumed;
- host-native accelerator placement behind a local-only node port, rather than an in-cluster service address;
- the harness ownership bracket's full release path against a real provider, from a pristine host.

## Sprints

### Sprint 25.1: The Lima provider realization [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`,
`core/hostbootstrap-core/test/LimaSpec.hs`
**Substrates**: apple-silicon
**Docs to update**: `documents/engineering/lima.md`

#### Objective

Implement the provider interface for Lima.

#### Deliverables

- Provisioning applies the project's declared sizing; the VM is created at budget rather than at a default.
- Reboot-to-ready observes readiness; the durable host-path share is mounted through the per-substrate primitive.
- Teardown deletes the VM on every path, so a run does not leave an instance behind.
- The guest alias uses the shared clause-holding backend, with its userland facts read off the probe.

#### Validation

`LimaSpec` covers the argument shapes and each operation. Dated live evidence: the Apple/Lima lifecycle lane
reported `10/10`, exercising `ensure lima`, `vm up` at budget, the durable share, the guest alias, and VM
deletion on every teardown.

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
- Record the observed duration; the envelope is 60–80 minutes over four bring-ups and four destroys, not the
  25–50 minutes an earlier estimate assumed.
- The in-container `check-code` runs on each bring-up, which is the only place `fourmolu` and `hlint` execute.

#### Validation

The `10/10` report plus the audited end state. Dated evidence: recorded on Apple M1 Max, macOS 25.5.0 arm64,
GHC 9.12.4, Lima provider, from a pristine host — `10/10 passed` in ~73 minutes, with both leases closed, no
surviving records, the generated config gone, the durable root intact, and the Lima instance removed.

#### Remaining Work

The recorded acceptance predates the currently-open work in the recursive-lifecycle-command,
prepared-operations, step-algebra, authenticated-handoff, and recovery phases. Acceptance is re-run once those
land, because each changes behaviour this lane exercises.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — the Apple realization's place in the provider dispatch.

**Engineering docs to create/update:**
- `documents/engineering/lima.md` — the Lima provider lifecycle.
- `documents/engineering/accelerator_daemon.md` — the Metal worker and host-native placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the Apple sequence, the duration envelope, and the pristine-host
  precondition.
