# Phase 26 — NVIDIA GPU substrate

**Status**: Done
**Depends on**: Phase 24 (the worked demo)
**Substrates**: nvidia
**Gate**: repository Python-bootstrapper `poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed` on a native Linux host with an NVIDIA GPU, followed by the terminal ownership audit
**Gate kind**: deferred
**Gate evidence**: 2026-09-14 ; `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, NVIDIA GeForce RTX 5090 on driver 595.84, Docker 29.7.1, Kind 0.32.0,
kubectl 1.37.0, Helm 3.16.3, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1, against the pinned
base `basecontainer-cuda-amd64@sha256:e4faab53cfaf88898c4e7c5c838396daa08f82cf4cb387906b8d35d181fdfa7a` ;
repository Python bootstrapper `poetry run hostbootstrap run --project-root demo test init` then
`poetry run hostbootstrap run --project-root demo test run all` ; pass ;
covers cbbaa6b6e13052bd9e4adb981b64b0de86a34b2d10c0bd0797118b1720e1165b
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

## What one Linux/NVIDIA visit records

This phase declares exactly one substrate beyond the baseline (§ II), and its gate is the live matrix on a
native Linux host with an NVIDIA GPU. That machine is also, unavoidably, an x86_64 Linux gate host, so a
visit to it records two cells (§ JJ):

| Cell | Owned by |
|---|---|
| NVIDIA substrate acceptance | this phase |
| x86_64 Linux gate host, host static gate | [phase 28](phase-28-host-portability-acceptance.md) |

The second row is not this phase's closure condition and never becomes one (§ C). It is recorded on the
same visit because the alternative is convening the machine twice for evidence one sitting can produce.

What this phase does **not** confirm is that the host static gate passes on a Linux outer host. That is a
§ JJ obligation every phase holds over its own suites, and Linux is an outer host realization there rather
than a declared substrate. This phase's gate is the live `10/10` demo run and the accelerator behavior
above.

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
- Before leaving the machine, also record the complete host static gate on it for
  [phase 28](phase-28-host-portability-acceptance.md)'s x86_64 Linux cell (§ JJ). It is not a closure
  condition of this phase and does not become one; it is collected here because this visit is the one that
  can produce it.

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
208 covered files, digest `dc81c1b3b2af462ef0e9590b741211b055bf57ceb4082cb75833f10f70f7c0aa`.
The lifecycle compiler annotations and exact Down-to-Destroy continuation changed this phase's covered
source set after that run, so it is retained as the prior dated result rather than as current-tree
acceptance. The run below supersedes it for currency.

On 2026-09-11, the current covered tree passed on the same host: `matt-junction`, native x86_64
Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic, NVIDIA GeForce RTX 5090 on driver 595.84, GHC 9.12.4,
Cabal 3.16.1.0, Python 3.12.3, and Poetry 2.4.1. Static preflight passed first: from `core/`,
`cabal build all --ghc-options=-Werror` in 114.56 seconds and `cabal test all --ghc-options=-Werror`
at 2,505/2,505 core cases in 169.73 seconds, with the provider-live component reporting
`Unsupported: provider-live not requested`; from the repository root, the Python code check passed and
the Python suite passed 235/235.

The repository Python bootstrapper's `poetry run hostbootstrap run --project-root demo test init`
initialized the two variants, and `poetry run hostbootstrap run --project-root demo test run all`
passed **10/10** in **51 minutes 35 seconds** (11:01:33 to 11:53:08 EDT), exit status 0. Every case
passed in both variants: `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and
`durable-readback`, for `hello-world` (`run-b9d0f80ba221f`) and `hello-universe` (`run-b9e805768832f`).

All four generations pulled published CUDA/amd64 base digest
`sha256:90f423e5659e3c5642664224735cf261d542f6de8394bd68f71aec57fbb62fc4`, built with `--no-cache`, ran
the in-container `check-code` and export checks, and published these derived digests to their run-local
registries on ports 32822, 32825, 32828, and 32831:

| Variant | Generation | Derived image digest |
|---------|------------|----------------------|
| `hello-world` | 1 | `sha256:e6d90608f73c0a74b73da066817fd99dbb61bb4daade19be8f94a0654eff25b9` |
| `hello-world` | 2 | `sha256:fb4c5cefa03cba1555c57c616da48ec78f958709178512bbb68df34fbfff00ab` |
| `hello-universe` | 3 | `sha256:19961d3c34bb658546b56e3209469edec093d332fec57beb7beecc8721012e39` |
| `hello-universe` | 4 | `sha256:60689e8ebfcd1ed552f96cdb0a1c142ea9f80a0f06cca02a8ec62c7da7f72629` |

The one-GPU request was **observed live through the Kubernetes API during the run**, not inferred from a
successful rollout. On `hello-world` generation 1, Running pod `accelerator-daemon-5cf57b99c6-gbx8h`
selected RuntimeClass `nvidia` with request and limit `nvidia.com/gpu: 1` on the GPU worker, alongside
device plugin `nvidia-device-plugin-rv99v`; that worker advertised one allocatable GPU and the
control-plane advertised none. The host driver concurrently reported the compute process
`/workspace/demo/.build/accelerator/linux-gpu/fc76cd884d2539b8/accelerator-worker` holding 500 MiB, and
`fc76cd884d2539b8` is the artifact identity the daemon announced and the browser assertion checks.

The same observation held on the recreated and second-variant clusters, with every pod identity distinct,
which is what establishes that each generation was genuinely fresh rather than a surviving cluster:

| Generation | Accelerator pod | Device plugin pod |
|---|---|---|
| `hello-world` 1 | `accelerator-daemon-5cf57b99c6-gbx8h` | `nvidia-device-plugin-rv99v` |
| `hello-world` 2 (same-run recreation) | `accelerator-daemon-f496cb4c7-ghrnw` | `nvidia-device-plugin-dvj8m` |
| `hello-universe` 3 | `accelerator-daemon-786bdbd8bc-wlbbb` | `nvidia-device-plugin-mnksr` |

The terminal audit found both leases `closed` (`run-b9d0f80ba221f`, `run-b9e805768832f`), both profiles
`available`, and no project mode, generated-config, or data-root ownership row. The generated
`.build/hostbootstrap-demo.dhall` was gone while `.build/hostbootstrap-demo.test.dhall` remained,
`.test_data` remained present and empty, no container of either run survived, `incus list` reported no
instance, and the driver reported no accelerator compute process. Unrelated ambient Docker workload on
this host was left untouched, so the container finding is "no container of this run" rather than a claim
of an empty daemon. The terminal source measurement matched the in-run tree across all 208 covered files
at digest `dbd7ee8515737e4c8391a9337a1815eb7db8de2d6dc28a4893e0b099b669b83e`.

Per § JJ this visit also recorded the x86_64 Linux gate-host cell for
[phase 28](phase-28-host-portability-acceptance.md), so the machine is not owed a second visit.

#### Remaining Work

None.

### Sprint 26.5: The NVIDIA acceptance against the current tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: nvidia
**Docs to update**: `documents/engineering/testing.md`

#### Objective

This phase's evidence covers the host-portable tree, so ordinary source change expires its claim —
which § G names as the expected state for an acceptance phase between runs rather than as an unclosed
phase. The claim is re-established by running the gate on an NVIDIA Linux host, not by re-recording a digest
over a tree nothing re-tested. That visit also carries the x86_64 Linux gate host.

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

None. On 2026-09-14 the matrix reported `10/10 passed` and exited 0 in 51m27s (02:57:44Z to 03:49:11Z),
from a pristine demo state, on the host the row above names. Both variants passed all five cases:
`pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence` and `durable-readback`.

Accelerator placement was observed rather than inferred: each of the four bring-ups reported
`cluster reconcile: NVIDIA device plugin and allocatable GPU are ready` before the workload was
released.

The terminal audit is clean. `kind get clusters` reports none, `incus list` is empty, no
hostbootstrap-named container survives, `.build/hostbootstrap-demo.dhall` is gone while
`.build/hostbootstrap-demo.test.dhall` remains, and `.test_data` exists with zero entries.

This run is the second of the day on this hardware. The first also reported `10/10` in 53m25s, against
the tree before the base image's compiler was pinned; it is not recorded as this phase's evidence,
because pinning the compiler touched `hostbootstrap/` and expired its digest in the same session. The
two durations are the before-and-after of that pin, and the near-parity is explained in
[the base-image phase](phase-23-base-image-and-warm-store.md).

### Sprint 26.6: The NVIDIA acceptance against the reconciled tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: nvidia
**Docs to update**: `documents/engineering/testing.md`

#### Objective

The documentation-reconciliation phase added drift checks to
`core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`, which is under this phase's
`**Evidence covers**`. The recorded run therefore names a tree that no longer exists, and § G names that
as the expected state for an acceptance phase between runs rather than as an unclosed phase. The claim
is re-established by running the gate again on an NVIDIA Linux host, not by re-recording a digest over a
tree nothing re-tested.

#### Deliverables

- The phase's declared gate is re-run in full on the hardware it declares.
- A gate-evidence row records the date, the gate host, the command as run, and the result.
- The covers digest is re-measured over this phase's own paths and recorded.
- The terminal ownership audit is re-observed, and accelerator placement is observed rather than inferred.

#### Validation

The phase's own gate, on its own hardware. Re-recording the digest without the run is the one thing
this sprint may not do.

#### Remaining Work

None. On 2026-09-14 the matrix reported `test report: 10/10 passed` and exited 0 in 3,363.60 seconds
(56 minutes 4 seconds), from 16:22:35Z to 17:18:39Z, on the host the row above names. Both variants
passed all five cases: `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence` and
`durable-readback`, as `hello-world` (`run-c8d39184feb9`) and `hello-universe` (`run-c8ed0f03964d`).

The harness `test init` entry refused, because the operator-owned `.build/hostbootstrap-demo.test.dhall`
was already present at its exact hash `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`;
the matrix ran from that file. Each of the four pristine generations pulled the pinned CUDA base and
built its own derived image:
`sha256:3848bca779dd19a3d782da9e5fdd61e7b21abc798920cbb8afa62eba3a04495e`,
`sha256:911d98b8a68dd9e64a36b11a3fab72733f55fadfdd21a53877cfa8a0135e74bf`,
`sha256:c1175fa166a40f50a5c3a006add20d5ba074b67b04a2f45b489124410336d9e5`, and
`sha256:c2c3a9f7beb7dedba8cdc3a30f3d4c3aa16e36fe8f72fa01eae476133fbef777`.

Accelerator placement was observed rather than inferred: each of the four bring-ups reported
`cluster reconcile: NVIDIA device plugin and allocatable GPU are ready` before the workload was released.

The terminal audit is clean. `kind get clusters` reports none, no hostbootstrap-named container survives,
`.build/hostbootstrap-demo.dhall` is gone while `.build/hostbootstrap-demo.test.dhall` remains, and
`.test_data` exists with zero entries. Two pieces of ambient state are unrelated to this lane and were
present before it: one exited container from a previous day, and the `hb-linux-cpu` guest that is the
worked demo's own `linux-cpu` gate host on this machine.

An earlier run the same day also reported `10/10` in 3,344.77 seconds. It is not recorded as this phase's
evidence, because the recursive lifecycle command's pre-descent repair landed under this phase's
`**Evidence covers**` while that run was in flight; the run above is the one against the settled tree.

### Sprint 26.7: The NVIDIA acceptance against the settled tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: nvidia
**Docs to update**: `documents/engineering/testing.md`

#### Objective

The worked demo's live gate found two repairs after the run Sprint 26.6 records, and both landed under
this phase's `**Evidence covers**` — the consumer's provider reverse in `demo/src` and the reverse
driver's reachability step in `core/hostbootstrap-core/src`. The recorded run therefore names a tree that
no longer exists. § G names that as the expected state for an acceptance phase between runs; the claim is
re-established by running the gate again, not by re-recording a digest.

#### Deliverables

- The phase's declared gate is re-run in full on the hardware it declares.
- A gate-evidence row records the date, the gate host, the command as run, and the result.
- The covers digest is re-measured over this phase's own paths and recorded.
- Accelerator placement is observed rather than inferred, and the terminal ownership audit is re-observed.

#### Validation

The phase's own gate, on its own hardware. Re-recording the digest without the run is the one thing
this sprint may not do.

#### Remaining Work

None. On 2026-09-14 the matrix reported `test report: 10/10 passed` and exited 0 in 3,223.94 seconds
(53 minutes 44 seconds), from 17:34:58Z to 18:28:42Z, on the host the row above names. Both variants
passed all five cases — `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence` and
`durable-readback` — as `hello-world` (`run-c912c61c28b1`) and `hello-universe` (`run-c92a0baf2bf8`).

The harness `test init` entry refused because the operator-owned `.build/hostbootstrap-demo.test.dhall`
was already present at hash `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`; the
matrix ran from that file. Each of the four pristine generations pulled the pinned CUDA base and built its
own derived image: `sha256:45ba6f68b8d073dd6204d443080c0b4a764447437993892ca85d31374de034a2`,
`sha256:58896827ba5b4bc27f2b80d096635072038a0011a4e1fa42e1bf51801394e430`,
`sha256:73bca62b2014bfcd2ba57d735c5ab6413a4f5e3def3c1298a819c64b5904d3e9`, and
`sha256:763a774118d7db0350a953e5ce4cedfe6b9f3a7d3485bd8f1cfd35977f785ce4`.

Accelerator placement was observed rather than inferred: each of the four bring-ups reported
`cluster reconcile: NVIDIA device plugin and allocatable GPU are ready` before the workload was released.

The terminal audit is clean. `kind get clusters` reports none, no hostbootstrap-named container survives,
`.build/hostbootstrap-demo.dhall` is gone while `.build/hostbootstrap-demo.test.dhall` remains at its
exact hash, and `.test_data` exists with zero entries. One exited container from the previous day is
ambient state this lane neither created nor touched.

Two earlier runs the same day also reported `10/10`, in 3,344.77 and 3,363.60 seconds. Neither is recorded
as this phase's evidence: the worked demo's live gate found a repair under this phase's
`**Evidence covers**` after each of them, and § G admits only a run against the tree the row measures.
The three durations are within 4% of each other, which is the useful thing they say together.

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
