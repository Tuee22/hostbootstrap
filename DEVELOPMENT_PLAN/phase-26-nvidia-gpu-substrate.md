# Phase 26 — NVIDIA GPU substrate

**Status**: Done
**Depends on**: Phase 24 (the worked demo)
**Substrates**: nvidia
**Gate**: repository Python-bootstrapper `poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed` on a native Linux host with an NVIDIA GPU, followed by the terminal ownership audit
**Gate kind**: deferred
**Gate evidence**: 2026-09-09 ; native x86_64 Ubuntu 24.04.4 LTS, NVIDIA GeForce RTX 5090, driver 595.84, Docker 29.7.1, GHC 9.12.4, Cabal 3.16.1.0 ; repository Python bootstrapper `poetry run hostbootstrap run --project-root demo test run all` plus terminal ownership audit ; pass ; covers dc81c1b3b2af462ef0e9590b741211b055bf57ceb4082cb75833f10f70f7c0aa
**Evidence covers**: `core/hostbootstrap-core/src` `core/hostbootstrap-core/internal` `demo/src` `demo/app` `demo/test` `demo/docker` `hostbootstrap`

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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: nvidia
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Bring up a GPU-capable cluster from the finalized plan.

#### Deliverables

- The accelerator-capable cluster driver is selected from the classified substrate, and its configuration is
  rendered from the one finalized plan rather than assembled by string edits.
- A workload declaring a device requirement receives a one-GPU request, and the budget preflight accounts for it.
- `ensure cuda` reconciles the CUDA toolchain on the host and is a no-op when present.
- The exact Direct/nvkind adopter waits through the shared bounded node-readiness policy before settling the
  fresh strong-backend observation; an identity conflict or probe fault refuses immediately rather than being
  retried as ordinary startup latency.
- Direct reverse recovers the exact Docker-visible durable profile bind and re-enters the project image through
  a fixed internal route. The core retained-cluster transaction authenticates every bound node identity, deletes
  with the pinned toolchain, proves absence, and releases the ownership record; the outer frame then independently
  proves every declared node absent. Harness alone restores traversal/write permission on non-symlink descendants
  of that exact data root before its owner removes it. Production durable state is never permission-normalized.
- The Direct child observes the source of its exact admitted durable bind from its own Docker container and
  renders that canonical metal-host path into nvkind. It never substitutes the provider-guest
  `/var/tmp/hostbootstrap-demo-data` alias, and reverse permission restoration runs against the child-visible
  side of the same bind rather than asking the metal Docker daemon to reinterpret that path.
- Because the Direct child uses host networking and therefore inherits the metal hostname, bind observation
  inspects the current running-container set and accepts only the unique container whose destination equals the
  exact run-profile path. Absence, duplication, malformed container identities, and inspection faults refuse.
- Before an accelerator workload is released, the exact Direct/nvkind adopter verifies the metal Docker NVIDIA
  runtime and the exact `nvidia` RuntimeClass that nvkind creates, installs the pinned NVIDIA device plugin when
  GPU capacity is not already advertised, waits for its DaemonSet, and requires positive `nvidia.com/gpu`
  allocatable capacity. The plugin and workload both select that runtime; a missing/foreign class or failed
  probe refuses rather than being treated as startup latency.
- The strong cluster backend carries the finalized driver into its clause-holding creation transaction: Kind
  uses `kind create cluster --config`, while nvkind uses `nvkind cluster create --config-template`. Listing,
  kubeconfig readback, identity binding, and conditional deletion continue through Kind after either creator.
- Kind creation remains a quiet, strictly framed report. Nvkind has no quiet flag, so its exact creation branch
  classifies process absence/non-zero exit while treating successful progress streams as non-authoritative;
  success still grants no ownership until fresh kubeconfig readback and every declared node identity bind.

#### Validation

`ClusterBackendSpec` covers the driver selection and the rendered configuration. `ClusterConfigSpec` and
`CommandsSpec` cover bounded readiness and allocatable-probe classification, exact Direct bind-source selection,
distinct provider-guest/Direct rendered paths, closed Production/Harness retained-release routes, declared-node
absence, and Harness-only permission restoration through argument-vector effects. On 2026-08-27, the complete demo
gate passed 149/149 tests, the final core gate passed 2,478/2,478 tests with `-Werror`, and the Python check-code and
231/231-test gates passed. In the live Direct Harness run `run-7040756432cff`, nvkind created the exact
`nvidia` RuntimeClass, the pinned device plugin became Ready on the worker, and that worker advertised one
allocatable `nvidia.com/gpu`. The Running accelerator pod selected that RuntimeClass, carried request/limit
`nvidia.com/gpu: 1`, ran on the exact GPU worker, and reported an NVIDIA GeForce RTX 5090 on driver 595.84.
The first complete post-fix gate then proved both variants' settled reverse and same-run durable recreation,
but reported 9/10 because Chromium's first navigation alone received `ERR_NETWORK_CHANGED`; the other fourteen
browser checks, including Firefox/WebKit and the CUDA daemon result, passed. The browser fixture now retries only
that explicit one-navigation Docker-network transient once; a different or repeated navigation fault still fails.
The clean follow-up matrix used Harness runs `run-707a32c651259` and `run-708bef9d2126e`; all four cluster
generations released their retained node records after exact physical deletion, and both same-run recreation
bound fresh clusters without a stale-record conflict.

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

### Sprint 26.3: NVIDIA GPU acceptance [Done]

**Status**: Done
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

On 2026-08-27, the pristine native Linux/NVIDIA matrix completed in about 42 minutes and reported `10/10
passed` for Harness runs `run-707a32c651259` and `run-708bef9d2126e`. Every one of its four project-image
bring-ups pulled base digest `sha256:90f423e5659e3c5642664224735cf261d542f6de8394bd68f71aec57fbb62fc4`,
ran the in-container `check-code`, and pushed derived manifests
`sha256:04a2dca938cabd571a1938508221f48f38a3d0fcc806b60cabdf2fd2057e69a4`,
`sha256:c3b4a89e8c7df56103ae92d58313ab9f0bedf410d5851c82acbea43672242be7`,
`sha256:51adcecad426df976ca3d834519f7c53a34854916f128fcf5c1156486a218e4e`, and
`sha256:e6f30fc760ccb761e028426fb6bc876075349a35ff67272f4337551cf23608f1`.

The worker advertised positive `nvidia.com/gpu`; the Running accelerator Deployment selected RuntimeClass
`nvidia`, requested and limited one GPU, and its CUDA worker served the browser calculation on an NVIDIA
GeForce RTX 5090 with driver 595.84. Both `durable-readback` rows crossed an engine-owned settled reverse,
fresh protected generation, exact plan rebind, and nvkind recreation before reading the retained bytes.

The terminal audit found both run leases `closed`, their lifecycle profiles `available`, no project mode,
generated-config, or data-root ownership row, no generated `.build/hostbootstrap-demo.dhall`, an empty preserved
`.test_data` parent, and no hostbootstrap-named container. The unrelated ambient Docker workload was left
untouched. Fourmolu and HLint were clean; the final core gate passed 2,478/2,478 under `-Werror`, the demo gate
passed 149/149, and the Python check-code plus 231/231 tests passed.

#### Remaining Work

None.

### Sprint 26.4: The NVIDIA acceptance run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: nvidia
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Record the dated live acceptance matrix on a native Linux host with an NVIDIA GPU.

#### Deliverables

- Initialize the pristine demo with the repository Python bootstrapper:
  `poetry run hostbootstrap run --project-root demo test init` from the repository root.
- Run `poetry run hostbootstrap run --project-root demo test run all` and record `10/10 passed`,
  naming the host, toolchain, accelerator, duration, run IDs, and published base and derived-image digests.
- Observe the Running accelerator workload's one-GPU request and audit the terminal run leases,
  ownership records, generated config, preserved durable parent, and absence of the run's containers.
- Record a passing gate-evidence row with the declared source paths' digest only after the live matrix
  and audit pass.

#### Validation

The dated live run and terminal ownership audit.

On 2026-09-09, static preflight passed on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, and Poetry 2.4.1.
From `core/`, `cabal build all --ghc-options=-Werror` passed and
`cabal test all --ghc-options=-Werror --test-show-details=direct --test-options=--hide-successes`
passed 2,497/2,497 core cases in 165.94 seconds of suite execution after the Hackage refresh,
including the documentation validator (174.20 seconds for the complete Cabal command). The provider-live
component reported `Unsupported: provider-live not requested`, as expected for static preflight.
From the repository root, `poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 235/235 in 1.57 seconds.

On the same date and host, the repository Python bootstrapper's
`poetry run hostbootstrap run --project-root demo test init` initialized the two variants, and
`poetry run hostbootstrap run --project-root demo test run all` passed **10/10** in **3,177.18 seconds**
(52 minutes 57 seconds). The matrix began without Docker containers, Incus instances, or pre-existing
demo Production state. Both `hello-world` (`run-affca409369d4`) and `hello-universe`
(`run-b0137ecc5f464`) passed pristine bootstrap, web build, end-to-end tabs, registry persistence,
and durable readback. Each durable-readback case crossed settled destruction and fresh same-run
cluster recreation before reading its retained bytes.

All four image generations pulled published CUDA/amd64 base digest
`sha256:90f423e5659e3c5642664224735cf261d542f6de8394bd68f71aec57fbb62fc4`, passed the in-container
`check-code` and export checks, and published these derived image digests to their run-local registries:

| Variant | Generation | Derived image digest |
|---------|------------|----------------------|
| `hello-world` | 1 | `sha256:1a8a5171cc6a5dccbe0875cd3b991799bee0cd0746722ba62b05769dd2a1df1e` |
| `hello-world` | 2 | `sha256:e4cebc2b2b80283e08e3a413b9ead6b39356a1b0b43e7983d917abfb026e5992` |
| `hello-universe` | 1 | `sha256:2449625fbbeaedf5d26ad4e24afd82f8ea854e9714184bee03c3d28e5367930b` |
| `hello-universe` | 2 | `sha256:a19c96e9c0cc88a586967b7a29d2b7f9a18380f6e2c96f90e9e47657ed8812ab` |

Live API observations captured Running accelerator pods `accelerator-daemon-797cfc86f7-dlr9p`
and `accelerator-daemon-5864594989-x52vq` on their respective run's GPU worker. Both selected
RuntimeClass `nvidia` and requested and limited `nvidia.com/gpu: 1`; the observed worker advertised
one allocatable GPU. The host GPU was an NVIDIA GeForce RTX 5090 on driver 595.84, and the
nvkind node image was `kindest/node:v1.36.1`. All four bring-ups reported the NVIDIA device plugin
and allocatable GPU ready before releasing the accelerator workload.

The terminal audit found both leases `closed`, both profiles `available`, no project mode or either
run's generated-config/data-root record, and no generated `.build/hostbootstrap-demo.dhall`.
The test config remained, `.test_data` remained empty, and neither run data directory survived.
Docker reported no running or stopped containers, Incus reported no instances, and NVIDIA reported
no compute process. The terminal source measurement matched the in-run measurement across all
208 covered files; the header records that digest.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — GPU classification and the driver selection.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
- `documents/engineering/cluster_lifecycle.md` — the accelerator-capable cluster driver.
- `documents/engineering/accelerator_daemon.md` — the CUDA worker and in-cluster placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the GPU sequence and its device-request expectation.
