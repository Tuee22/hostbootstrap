# Phase 26 — NVIDIA GPU substrate

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: nvidia
**Gate**: live `hostbootstrap run -- test run all` reporting `10/10 passed` on a native Linux host with an
NVIDIA GPU

> **Purpose**: Add the GPU realizations — the accelerator-capable cluster driver and the CUDA worker — and
> confirm the whole build on that substrate.

## Phase Objective

This is an **acceptance phase** (§ II). Nothing depends on it, so a machine without an NVIDIA GPU stops at the
worked-demo phase. It carries exactly one substrate beyond the baseline, and it is a genuinely different host
from the baseline lane: substrate classification reads `/proc/driver/nvidia/version` and `/dev/nvidiactl`, so a
host with no NVIDIA markers classifies as `linux-cpu` and cannot stand in for this lane.

## What this phase confirms

- the accelerator-capable cluster driver, including a one-GPU device request that the scheduler honours;
- the CUDA worker built by `nvcc` on the host toolchain, reached over the private listener;
- in-cluster accelerator placement behind a service address, which is the placement the Apple lane does not use;
- the direct-host provider path, where the cluster runs without an intervening VM;
- the single metal-to-container descent, where the cluster lives in a frame the metal host cannot see directly.

## Sprints

### Sprint 26.1: The accelerator cluster driver [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`
**Substrates**: nvidia
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Bring up a GPU-capable cluster from the finalized plan.

#### Deliverables

- The accelerator-capable cluster driver is selected from the classified substrate, and its configuration is
  rendered from the one finalized plan rather than assembled by string edits.
- A workload declaring a device requirement receives a one-GPU request, and the budget preflight accounts for it.
- `ensure cuda` reconciles the CUDA toolchain on the host and is a no-op when present.

#### Validation

`ClusterBackendSpec` covers the driver selection and the rendered configuration. Dated live evidence: the direct
`nvkind` lane reported `10/10 passed` on a native Linux GPU host.

#### Remaining Work

None.

### Sprint 26.2: The CUDA worker and in-cluster placement [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Accelerator/`
**Substrates**: nvidia
**Docs to update**: `documents/engineering/accelerator_daemon.md`

#### Objective

Build and run the CUDA worker in the cluster.

#### Deliverables

- The worker is compiled by `nvcc` and its artifact hash is asserted through the browser assertion.
- The daemon runs as an in-cluster deployment, applied and rollout-waited before any client connects, and reached
  at its own service address — the placement the host-native lanes do not use.
- The private-listener contract and the CBOR round trip are the same as every other lane; only the placement
  differs.

#### Validation

Dated live evidence: `e2e-tabs` passed on both variants, asserting the daemon-returned sum, backend, and artifact
hash through the browser on the GPU lane.

#### Remaining Work

None.

### Sprint 26.3: NVIDIA GPU acceptance [Active]

**Status**: Active
**Implementation**: the whole tree
**Substrates**: nvidia
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Confirm the current build on this substrate.

#### Deliverables

- From a pristine host, run `test init` then `hostbootstrap run -- test run all` and record `10/10 passed`.
- Audit the same end state the other acceptance phases audit: leases closed, no surviving mode/config/data-root
  records, the generated sibling config gone, the durable root intact, and every provider frame removed.
- Confirm the one-GPU request was honoured rather than silently scheduled without a device.
- The in-container `check-code` runs on each bring-up.

#### Validation

The `10/10` report plus the audited end state, recorded with the host's GPU model and driver version.

#### Remaining Work

Run the complete acceptance gate after the recursive-lifecycle-command, prepared-operations,
step-algebra, authenticated-handoff, recovery, and worked-demo dependencies are closed. The run must
exercise typed frame-indexed teardown descent across the real metal-to-container boundary, the complete
current test matrix, and a current GPU/provider observation including the honoured one-GPU request.

## Remaining Work

Sprint 26.3, the acceptance run itself. Sprints 26.1 and 26.2 are closed with their own dated live GPU
evidence; what is left is the pristine-host re-run of the complete matrix against the current tree,
which is owed to a native Linux host with a real NVIDIA device and to nothing else.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — GPU classification and the driver selection.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` — the accelerator-capable cluster driver.
- `documents/engineering/accelerator_daemon.md` — the CUDA worker and in-cluster placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the GPU sequence and its device-request expectation.
