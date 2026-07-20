# Phase 5: Cluster Lifecycle and Resource Cordoning

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Land kind/Helm cluster-lifecycle semantics, resource-budget verification and
> cordoning (VM wall on Apple, kind node limits on Linux), the never-delete-`.data`
> invariant, and the production-vs-test cluster profile.

## Phase Status

**Status**: Active

**Reopened then closed (2026-07-05, cross-substrate reliability hardening).** The demo real-run gate (Sprint
13.16) surfaced cluster-lifecycle readiness/idempotency gaps in this phase's scope: `kind create` (default
`--wait 0s`) is followed by an immediate `kubectl apply` with no node-Ready/CNI gate; `clusterCreate`
trusts `kind get clusters` with no health check (a stopped in-VM cluster reads as running); and the
`down`-deletes-kind / `up`-recreates contract does not hold for the VM-nested demo cluster (`down` only
stops the VM). The fixes landed (see `## Remaining Work`) and **closed 2026-07-05** by a live Windows/WSL2
`hostbootstrap-demo test run all` reporting **`test report: 6/6 passed`** across both message variants — the
`cluster up: nodes Ready for hostbootstrap-demo` gate fired on each of the two bring-ups before the first
apply, then `project destroy` tore down cleanly.

The cluster lifecycle is now reached **only** as `deploy-kind` / `deploy-chart` chain steps under
`project up` (the flat `cluster` verb group is removed; read-only liveness moved under `context`), and the
real-run gate is **met (2026-06-18)**: a live `project up` on Incus/Linux brought the cordoned kind cluster
up in the container frame (`clusterCreate` preflight + `kind create` + `kind export kubeconfig` + the Linux
cordon, then the registry + web charts), and `project down` / `project destroy` tore it down. The pure
cores below are unchanged and unit-tested.

`HostBootstrap.Cluster.Cordon` derives the substrate-specific cordon (`colimaSizingArgs`,
`kindNodeCordonArgs`, `incusSizingArgs`) and `verifyBudget` checks spare capacity;
`HostBootstrap.Cluster.Lifecycle` provides cluster bring-up/teardown with the
never-delete-`.data` invariant (per-case test data is under `./.test_data/<case>/`) and the
production-versus-test profile distinction. The pure cores (`parseQuantity`, `verifyBudget`,
`resolvePlan`, `teardown`, `statusReport`) are unit-tested. Bring-up runs the spare-capacity preflight
and applies the Linux `docker update` kind-node cordon after `kind create` and before Helm, fail-closed.
The incus VM storage cordon is provided by [Phase 11](phase-11-incus-host-provider.md). The kube tools are
container tools (§ L), so lifecycle operations run in the active context reached by the self-reference
lift when the workflow is lifted.

Under the "the chain is the project" model (§ Y, § W), cluster bring-up and teardown are no longer a
standalone `cluster` verb group: they become **chain steps** (`deploy-kind`, `deploy-chart`) interpreted
by the core `project` lifecycle command, driven by `project up` (bring up), `project down` (stop without
delete), and `project destroy` (delete). The flat `cluster` verb is **removed** (phase-4), and the new
**stop-without-delete capability** is implemented as the pure `stopVMArgs` argv builders in
`HostBootstrap.Incus` / `HostBootstrap.Lima`, unit-tested in `IncusSpec` / `LimaSpec`. The cordon derivation
and the never-delete-`.data` invariant carry forward unchanged. This work is **Done**: Phase 16 owns the
`project` lifecycle interpreter, and the container-frame apply is real-run-validated by the demo.

**Reopened 2026-07-09 for the accelerator Linux GPU cluster path.** The Linux GPU accelerator lane skips
the Incus VM and launches an `nvkind` cluster directly on the host through the project container. This phase
owns that cluster/exposure shape and the service exposure rule: in-cluster daemon pods use `ClusterIP`,
while host daemons reach the web accelerator ingress through a local-only `NodePort`.

**Static implementation landed 2026-07-09 and completed 2026-07-11.**
`HostBootstrap.Cluster.Lifecycle` now carries an explicit
`ClusterDriver` (`KindDriver` / `NvkindDriver`) on `ClusterPlan`, maps `linux-gpu` accelerator plans to
`NvkindDriver`, builds `nvkind cluster create --name=<cluster>` args while preserving the standard kind path
for Linux CPU and other substrates, and runs the same official volume-mount NVIDIA runtime smoke as
`ensure cuda` before the `nvkind` path creates the cluster. Plans carry an explicit config path and fail
closed when it is absent: host-daemon, Linux CPU, and direct Linux GPU placements select `kind.yaml`,
`kind-in-cluster.yaml`, and `nvkind-in-cluster.yaml`. The nvkind config uses a control-plane plus a GPU
worker labelled `nvidia.com/gpu.present=true`, divides the single declared cluster envelope across both
node containers, and omits the host-daemon-only accelerator mapping. Bring-up probes allocatable GPU first;
if none is positive, it installs NVIDIA device-plugin chart `0.19.3`, waits for its pods, and requires
positive allocatable `nvidia.com/gpu` before workloads may schedule. The same module exposes the pure
accelerator-ingress plan:
in-cluster daemons render a dedicated `ClusterIP`, while host-resident daemons render a distinct local-only
`NodePort` with kind listen address `127.0.0.1`. Placement-specific kind templates prevent that host-only
port from being published on in-cluster daemon lanes. Phase 5 remains `Active` only for the live daemon
integration gates below.

**Static hardening completed 2026-07-15.** The NVIDIA device-plugin reconciler now performs the
allocatable-GPU probe before any Helm or `kubectl` mutation: an already-positive
`nvidia.com/gpu` allocation returns as a true no-op, while an absent allocation takes the pinned
install/readiness path and then requires positive capacity. Cluster `down` / `delete` now attempt every
intended Kind and derived-path cleanup, preserve `.data`, aggregate all failures, and propagate the
aggregate after cleanup instead of reporting false success. Recovery from a listed-but-unhealthy cluster
now requires successful Kind deletion before recreation, so an unresolved or non-zero delete cannot be
followed by a misleading create attempt. At the `project down|destroy` command layer, core Kind cleanup
runs only when the current frame owns the chain's `deploy-kind` step. A root frame does not try to resolve
Kind for a cluster nested in a VM or project container; that cluster remains owned by the project's
teardown hook. When local core cleanup is attempted, its failures still aggregate and propagate. Focused
`LifecycleSpec` / `CLISpec` regressions cover both device-plugin branches, failure aggregation, and
frame-aware teardown ownership.

## Phase Objective

Land the cluster-lifecycle and resource contracts in `hostbootstrap-core` (see
[development_plan_standards.md § O](development_plan_standards.md)). `hostbootstrap` verifies the host
has the spare budget declared in `resources` and cordons it — on Apple by sizing a dedicated
per-project VM wall on Apple, on Linux by applying kind node resource limits — drives kind/Helm cluster
lifecycle, never enumerates the plan's `.data` path for removal, and distinguishes the production cluster
profile (fixed name / `.data` path) from the test profile (per-case isolated paths). What that
non-enumeration does and does not guarantee is
[durable_state](../documents/architecture/durable_state.md).

## Remaining Work

**Accelerator cluster/exposure work — implementation complete; real-host gates open.**

- **Landed (static):** Linux GPU accelerator plans select `nvkind`; Linux CPU and the non-GPU VM-backed
  paths stay on the existing kind/Incus shape.
- **Landed (static):** accelerator ingress planning renders `ClusterIP` for in-cluster daemon pods and a
  local-only `NodePort` (`127.0.0.1` kind host mapping) for host daemons.
- **Landed (static):** the Linux GPU direct path runs the official nvkind volume-mount NVIDIA runtime
  smoke before cluster creation, uses the CUDA base image and a `--gpus=all` project-container handoff,
  creates the control-plane + `nvidia.com/gpu.present=true` GPU-worker topology, and refuses to continue
  until `nvidia.com/gpu` is allocatable. Device-plugin `0.19.3` installation is idempotent: an already
  positive allocation is probed before any Helm or `kubectl` mutation and is a true no-op; otherwise Helm
  installs/upgrades the chart and bring-up waits for both plugin pods and positive allocatable capacity.
- **Landed (static):** the single cluster slice is divided across both nvkind node containers rather than
  applied in full to each node, preserving the one-budget/one-cordon contract.
- **Landed (static):** the direct Linux GPU chain performs the metal preflight plus `ensure docker` and
  `ensure cuda`, skips Incus in its harness/safety/teardown paths, and deploys the CUDA daemon pod with a
  `nvidia.com/gpu: 1` limit.
- **Landed (static):** cluster `down` / `delete` attempt all intended Kind and derived-path cleanup,
  aggregate failures, propagate the aggregate, and never remove `.data`.
- **Landed (static):** `project down|destroy` invokes core Kind cleanup only when the current frame owns a
  `deploy-kind` step. Nested VM/project-container clusters skip expected host-side Kind lookup and remain
  owned by the project teardown hook; an attempted local cleanup still fails closed.
- **Landed (static):** listed-but-unhealthy cluster recovery requires the Kind delete step to succeed
  before recreation; unresolved or non-zero deletion fails closed.
- **Remaining (real-run-gated):** on a **native Linux CPU** host, run the Incus-backed lane through
  in-cluster daemon `ClusterIP` connectivity and the C++ worker; the four-case/two-variant matrix must
  report `8/8`.
- **Remaining (real-run-gated):** on a **native Linux GPU** host, run the direct `nvkind` lane through the
  CUDA daemon/worker and browser Add assertion; the four-case/two-variant matrix must report `8/8`.

Validation: unit tests for cluster profile/exposure rendering, integration tests for Linux CPU and Linux
GPU daemon connectivity, and the browser e2e add workflow through the web service.

Current static validation (2026-07-20): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` with 374 tests; the demo `-Werror` build and test run pass with
89 demo tests plus the embedded 374 core tests. Coverage includes fail-closed placement-specific cluster
configs, service/NodePort separation, official NVIDIA runtime probing, pre-mutation device-plugin
idempotence, install/readiness/allocatable classification, aggregate teardown failure propagation with
`.data` preservation, frame-aware command-level Kind ownership, fail-closed unhealthy-cluster deletion
before recreation, the worker label, two-node cordon splitting, direct-chain CUDA
image/`--gpus=all` handoff, daemon GPU requests, and the implemented browser Add assertion. The native
Linux CPU Incus/ClusterIP/C++ and native Linux GPU direct-nvkind/CUDA/browser gates remain open. Each
four-case/two-variant lane must report `8/8`; the latest completed live gate remains the historical
pre-accelerator `6/6` result. The Phase 3 closure remains its historical 359-test snapshot.

**Previously closed 2026-07-05 — cross-substrate cluster readiness + idempotency:**

- **Node/CNI readiness gate — landed.** `clusterCreate` now runs `waitNodesReady`
  (`kubectl wait --for=condition=Ready node --all --timeout=30s`, bounded-retry × 10 with a 3 s backoff,
  fail-closed) **after** `kind create` (`--wait 0s`) and the cordon and **before** it returns, so the chain's
  first `kubectl apply` / Helm install cannot race the API server or CNI on a busy host
  (`HostBootstrap.Cluster.Lifecycle.clusterCreate`).
- **Health-check-and-recreate — landed.** `clusterCreate` no longer trusts `kind get clusters`: a listed
  cluster is health-probed by `ensureCluster` → `clusterHealthy` (export kubeconfig, then
  `kubectl get nodes`; the pure classifier `clusterHealthyFromProbe` is unit-tested in `LifecycleSpec`), and
  a listed-but-unhealthy cluster (stopped containers → connection refused) is deleted and recreated. The
  2026-07-15 hardening makes that delete fail-closed with `requireStep`: recreation does not proceed when
  Kind is unresolved or deletion exits non-zero.
- **Reconcile the down/up contract for the VM-nested cluster — landed.** The health-check-and-recreate above
  **is** the mechanism: after a `project down` that stopped the VM (leaving the in-VM kind cluster stopped),
  the next `project up`'s in-VM `clusterCreate` sees the cluster listed-but-unhealthy and recreates it. The
  honest prose (`down` stops the VM, so the in-VM cluster is left stopped and a re-run health-checks-and-
  recreates) is already in [cluster_lifecycle.md](../documents/engineering/cluster_lifecycle.md). Co-owned
  with [Phase 16](phase-16-project-lifecycle-command.md).

Code-check gate (2026-07-05): `cabal build lib:hostbootstrap-core --ghc-options=-Werror` and `cabal test all`
(292) green. **Closed (real-run, § C, 2026-07-05):** the readiness gate + recreate were exercised by the live
Windows/WSL2 `project up` → `test run all` → `project destroy` run reporting **`6/6 passed`** — `cluster up:
nodes Ready for hostbootstrap-demo` fired on both bring-ups. **None remaining.**

The flat `cluster` verb is removed (phase-4) and the **stop-without-delete capability** is implemented
(`stopVMArgs` for Incus and Lima, unit-tested in `IncusSpec` / `LimaSpec`). The cluster bring-up/teardown
as real `deploy-kind` / `deploy-chart` / teardown step actions under `project up` / `project down` /
`project destroy` is closed and validated by the demo real runs.

Specifically:

- The standalone `cluster up|down|delete|status` verb group is dissolved; cluster bring-up becomes the
  `deploy-kind` / `deploy-chart` step kinds, and teardown becomes the descent-then-ascent stop/delete the
  `project` lifecycle interpreter performs over the chain (§ Y). The pure `resolvePlan`, `teardown`,
  `statusReport`, and cordon cores remain the implementation those steps call; they are not rewritten.
- Split bring-down into two distinct capabilities: `project down` stops provider VMs but deletes kind
  clusters at the frame that owns `deploy-kind`, while preserving durable state; `project destroy` stops
  then deletes everything spun up. A root frame skips core Kind lookup when the cluster belongs to a
  nested VM/project-container frame and delegates that nested cleanup to the project teardown hook. The
  old `cluster down` collapsed lifecycle framing; an owning cluster frame uses delete-on-down because kind
  has no reliable stop/restart contract.
- The never-delete-`.data` invariant is preserved across both `project down` and `project destroy`: the
  plan's `.data` path is never placed in any removal set (§ Y). That is the whole of the guarantee — it is
  not host mirroring, and `destroy` still deletes the provisioned frame the path lives in
  ([durable_state](../documents/architecture/durable_state.md)).
- The `project` lifecycle command, its step interpreters, and the stop-without-delete capability **ship**,
  and the flat `cluster` verb group is **removed** (§ Sprint 5.2). Phase 16 owns the interpreter; the
  dissolved `cluster` verbs are recorded under
  **Removed Surfaces** in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprints

### Sprint 5.1: Resource budget verification + cordoning [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`
**Docs to update**: `documents/engineering/resource_budgeting.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Cluster.Cordon`: verify the host has the spare `resources` budget and cordon it
to the project.

#### Deliverables

- Budget verification reading `resources {cpu, memory, storage}` and checking spare host capacity.
- Apple cordoning: **derive** the sizing for the dedicated VM wall from the budget.
- Linux cordoning: **derive** kind node resource limits from the budget.

The pure cordon derives the args; applying them happens through the project binary's lifecycle and host
provider flows.

#### Validation

- `CordonSpec` asserts a budget exceeding spare capacity fails fast naming the over-committed
  dimension, and that `colimaSizingArgs` / `kindNodeCordonArgs` reflect the declared budget. `cabal test`
  passes.

#### Remaining Work

None.

### Sprint 5.2: Cluster lifecycle + profiles + never-delete-.data [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `system-components.md`

#### Objective

Land `HostBootstrap.Cluster.Lifecycle`: kind/Helm `up`/`down`/`delete` semantics with the
never-delete-`.data` invariant and the production-vs-test profile distinction.

#### Command Surface

- `hostbootstrap cluster up` — bring the stack to running (idempotent), within the cordoned budget.
- `hostbootstrap cluster down` — tear the cluster down; the removal set is empty, so no path is removed.
- `hostbootstrap cluster delete` — thorough teardown of derived state; still never enumerates `.data`.

#### Deliverables

- kind/Helm lifecycle driving cluster creation, Helm release management, and teardown.
- The never-delete-`.data` invariant enforced on both `down` and `delete`.
- A `ClusterProfile` distinguishing production (fixed name / `.data` path) from test (per-case
  isolated paths), so the harness-driven test profile never collides with a production cluster.

#### Validation

- `LifecycleSpec` asserts `teardown Down` / `teardown Delete` never place `.data` in the removal set
  (for both profiles), and that the production and test profiles resolve distinct cluster names and
  host paths. `cabal test` passes; `hostbootstrap cluster --help` lists `up`/`down`/`delete`.

#### Remaining Work

None. The pure lifecycle/teardown cores and never-delete-`.data` invariant carry forward; the completed
Phase 16 interpreter now owns their `project up|down|destroy` command surface, and the container-frame
apply was real-run-validated by the demo.

### Sprint 5.3: Read-only `cluster status` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `system-components.md`

#### Objective

Add a read-only `cluster status` verb that reports whether the resolved cluster is live without
mutating any state, completing the Phase-5-owned command surface (the applied cordon and the
`verifyBudget`/one-parser work are Phase 9).

#### Command Surface

- `hostbootstrap cluster status` — probe `kind get clusters` and report the resolved cluster's
  liveness, the preserved `.data` path, and the derived paths. Never mutates state.

#### Deliverables

- The pure `statusReport :: ClusterPlan -> Bool -> String` renderer and the IO `clusterStatus` driver
  in `HostBootstrap.Cluster.Lifecycle`, with `cluster status` wired into the `cluster` command group.

#### Validation

- `LifecycleSpec` asserts the status report names the cluster, marks it running/absent, and always
  shows the preserved `.data` path. `cabal test` passes; `hostbootstrap cluster --help` lists
  `up`/`down`/`delete`/`status`.

#### Remaining Work

None. The pure renderer remains, liveness/`.data` introspection moved to the read-only `context` surface,
and the dissolved `cluster status` verb is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Sprint 5.4: Fail-closed `cluster up` and the in-container path [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `documents/architecture/composition_methodology.md`

#### Objective

Make `cluster up` fail-closed on its helm/kind steps, and run the lifecycle in the in-container path (the
kube tools are baked into the base image, not host tools — § L).

#### Deliverables

- `cluster up` uses `requireStep` for `kind create cluster` and `helm upgrade --install`: a non-zero exit
  or an unresolved tool `die`s, so a broken deploy is loud and a lifting parent process sees a non-zero
  exit. Listed-but-unhealthy cluster recovery also requires successful Kind deletion before recreate.
  Teardown attempts every intended Kind and derived-path cleanup, aggregates failures, and reports the
  aggregate after all cleanup has been attempted.
- `project down|destroy` runs that core Kind teardown only in the current frame that owns the chain's
  `deploy-kind` step. Nested clusters are left to the project teardown hook, so expected host-side absence
  of container-only Kind is not misreported as a cleanup failure.
- The lifecycle is invoked in the project container via the self-reference lift (`HostBootstrap.Lift`,
  phase-11), so `helm`/`kind` resolve on the container `$PATH` rather than the host.

#### Validation

- The pure `LifecycleSpec` is unchanged; the fail-closed behaviour and the in-container run are exercised
  in the [demo](phase-13-hostbootstrap-demo.md)'s real run. `cabal test` passes.

#### Remaining Work

None. The fail-closed `requireStep` discipline now hangs off `deploy-kind` / `deploy-chart` under
`project up`; the in-container path was exercised by the demo's completed real runs. The 2026-07-15 static
hardening makes teardown attempt every independent cleanup and propagate aggregate failures.
The command-level ownership check invokes that core cleanup only in a frame that owns `deploy-kind`;
nested cluster teardown remains project-owned.

### Sprint 5.5: Accelerator cluster exposure and Linux GPU nvkind [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/chart/templates/service.yaml`, `demo/kind.yaml`,
`demo/kind-in-cluster.yaml`, `demo/nvkind-in-cluster.yaml`
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/operations/demo_runbook.md`

#### Objective

Add the cluster/exposure substrate needed by the accelerator daemon demo, especially the Linux GPU direct
`nvkind` path.

#### Deliverables

- Linux GPU cluster path: launch `nvkind` directly on the host through the project container, without the
  Incus VM.
- Linux CPU cluster path stays Incus VM backed and runs a daemon pod in-cluster.
- Accelerator ingress: `ClusterIP` for in-cluster daemon pods, local-only `NodePort` for host daemons.
- Explicit placement configs: `kind.yaml` for host-daemon NodePort ingress, `kind-in-cluster.yaml` for the
  Linux CPU pod, and `nvkind-in-cluster.yaml` for a direct control-plane + labelled GPU worker without the
  host-only accelerator mapping.
- NVIDIA runtime probe for the Linux GPU integration path before the daemon pod builds the CUDA worker.
- Idempotent NVIDIA device-plugin `0.19.3` install/readiness and positive `nvidia.com/gpu` allocatable gate
  before scheduling.
- One declared cluster envelope divided across nvkind's control-plane and GPU worker containers.
- Direct-chain metal preflight plus `ensure docker`/`ensure cuda`, CUDA-base image selection,
  `--gpus=all` project-container handoff, and a daemon pod limited to one GPU.

#### Validation

- Pure tests for substrate-to-cluster-profile and exposure rendering.
- Linux CPU integration test: daemon pod connects by `ClusterIP` and returns an add result.
- Linux GPU integration test: direct `nvkind` cluster, CUDA daemon pod, `nvcc` worker build, add result.
- Browser e2e add test proves the UI path reaches the daemon-backed worker.

#### Remaining Work

Static lifecycle work is complete: driver/config selection, official NVIDIA runtime probing, two-node
cordon splitting, pre-mutation device-plugin no-op detection, pinned install/readiness/allocatable gates,
aggregate teardown failure propagation with `.data` preservation, fail-closed unhealthy-cluster deletion
before recreation, frame-aware command-level Kind ownership, labelled GPU worker, direct CUDA image and
`--gpus=all` handoff, and placement-specific service exposure are covered by the
374-core/89-demo test gates above.
The web chart exposes a distinct local-only `127.0.0.1:30081` accelerator NodePort only for host-daemon
lanes; Linux CPU/GPU daemon pods dial the distinct accelerator `ClusterIP` on the configured port (default
8081).

Open (real-run-gated, § C): a native Linux CPU Incus lane proving daemon-pod connectivity by `ClusterIP`
and the C++ worker at `8/8`, and a native Linux GPU direct-`nvkind` lane proving the CUDA-base,
one-GPU daemon pod, CUDA worker, and browser e2e Add workflow at `8/8`. The Windows GPU
host-daemon-through-the-local-only-NodePort path is exercised by the decoupled Windows/WSL2 durable gate
(Phase 13). No WSL2 result is represented as native Linux. No live `8/8` result is recorded yet, so the
historical `6/6` remains evidence only for the pre-accelerator matrix. No implementation or static-test
work remains in this sprint.

### Sprint 5.6: Host-durable project state [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`, `demo/kind.yaml`, `demo/chart/`
**Docs to update**: `documents/architecture/durable_state.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Make `.data` mean what the governed docs long claimed it meant: project state that genuinely outlives
`project destroy`. Today the never-delete-`.data` invariant guarantees only that cluster teardown does
not enumerate the path for removal — a real property, but a much narrower one. Nothing creates the
directory, and on a lifted topology it resolves inside a frame that `destroy` deletes.

#### Deliverables

- A durable-root contract that resolves to a **host** path regardless of which frame owns the cluster
  step, consuming the share primitive from phase-11 Sprint 11.8.
- The durable root carried across every boundary a nested chain crosses: VM → project container
  (a `Mount` on the container launch), container → kind node (`extraMounts` in the kind config, which
  today declares only `extraPortMappings`), kind node → pod (a host-backed volume in the chart).
- A create-on-`up` path, so the root exists rather than being vacuously preserved.
- `Capability.DurableStore` promoted from a declared-but-unread context capability to one a command
  actually requires (with phase-15), and removed from the `Pending` ledger when it lands.
- The teardown status line stops reporting `preserved` for a path it never inspected.

#### Validation

- `cabal test` from `core/` — the existing `LifecycleSpec` on-disk teardown cases continue to pass
  unchanged; new cases cover durable-root resolution across frames.
- Real-run gate (§ C), jointly with phase-11 Sprint 11.8: write state through the running stack, run
  `project destroy`, run `project up`, and read the same state back.

#### Remaining Work

Implementation and static validation are complete. The provider share from phase-11 Sprint 11.8 is
carried through the VM, project container, kind node, and web pod; the web service exposes the marker
write/read probe used by the real-run gate. The 2026-07-20 static gates pass: core `-Werror` build plus
374 tests, demo `-Werror` build plus 89 demo tests and the embedded 374 core tests, the Python code-check,
and all 180 Python tests. The joint real-run gate remains: write the marker through the running service,
run `project destroy`, run `project up`, and read the same marker from the host-backed root. Until that
gate passes, no governed document may describe host-durable `.data` as validated (§ J).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/durable_state.md` - the canonical home of the never-delete-`.data` invariant:
  the removal-set guarantee, frame-relativity, and the Sprint 5.6 durable-root contract.

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` - budget verification, Colima per-project VM sizing
  on Apple, kind cordoning on Linux.
- `documents/engineering/cluster_lifecycle.md` - kind/Helm semantics, the never-delete-`.data`
  invariant, the production-vs-test profile.
- `documents/engineering/accelerator_daemon.md` - accelerator ingress and Linux GPU `nvkind` cluster path.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.*` rows and the resource-cordoning
  section.
- WSL2 stop-without-delete on ascent (`wsl --terminate` without `wsl --unregister`) and WSL2-VM-boundary
  cordoning (the `.wslconfig` + vhdx wall) are owned by
  [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)'s Windows WSL2 host-provider sprint —
  the Windows peer of the Incus/Lima stop-without-delete and VM cordon carried here.
