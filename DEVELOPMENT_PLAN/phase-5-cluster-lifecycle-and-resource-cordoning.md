# Phase 5: Cluster lifecycle and resource cordoning

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
stops the VM at the root while the nested owning frame is not recursively invoked). The owning-frame
delete/recreate fixes landed and **closed their dated scope 2026-07-05** by a live Windows/WSL2
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
`kindNodeCordonArgs`, `incusSizingArgs`) and `verifyBudget` checks resolved substrate capacity;
`HostBootstrap.Cluster.Lifecycle` provides cluster bring-up/teardown with the
never-delete-`.data` removal-set invariant and an initial, forgeable production-versus-test profile
distinction. Sprint 5.7 replaces the underlying cluster/storage mutations with ownership-aware backend
operations and receipts. Sprint 10.9 consumes those primitives to replace the profile distinction with
opaque `Production projectId | Harness projectId runId` mode/profile authority over Phase 15.9's root
gate;
the current harness must not be described as isolated merely because a path has a `.test_data` name.
The pure cores (`parseQuantity`, `verifyBudget`,
`resolvePlan`, `teardown`, `statusReport`) are unit-tested. Bring-up runs the resolved-capacity preflight
and applies the Linux `docker update` kind-node cordon after `kind create` and before Helm, fail-closed.
The incus VM storage cordon is provided by [Phase 11](phase-11-incus-host-provider.md). The kube tools are
container tools (§ L), so lifecycle operations run in the active context reached by the self-reference
lift when the workflow is lifted.

Under the "the chain is the project" model (§ Y, § W), cluster bring-up and teardown are no longer a
standalone `cluster` verb group: they become **chain steps** (`deploy-kind`, `deploy-chart`) interpreted
by the core `project` lifecycle command. Current `project up` follows the chain recursively in the forward
direction. Current `project down` / `project destroy` do **not** derive and recurse through a reverse plan:
they attempt Kind cleanup only for the current owning frame, then invoke the independently supplied
`psTeardown` hook to stop or destroy the provider. Phase 16 Sprint 16.6 replaces those separable views with
one lifecycle plan whose reverse traversal is derived from the same resource identities as forward
execution. The flat `cluster` verb is **removed** (phase-4), and the
**stop-without-delete capability** is implemented as the pure `stopVMArgs` argv builders in
`HostBootstrap.Incus` / `HostBootstrap.Lima`, unit-tested in `IncusSpec` / `LimaSpec`. The cordon derivation
and the never-delete-`.data` invariant carry forward unchanged. This phase's cluster semantics are
**Done**; the lifecycle-plan unification remains Phase 16.6 work, and the container-frame apply is
real-run-validated by the demo.

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
port from being published on in-cluster daemon lanes. Phase 5 remains `Active` for the live daemon gates,
the durable readback gate, and the storage/ownership work in Sprints 5.6–5.7.

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
independently supplied teardown hook. Phase 16.6 derives that child-first cleanup from the unified plan.
When local core cleanup is attempted, its failures still aggregate and propagate. Focused
`LifecycleSpec` / `CLISpec` regressions cover both device-plugin branches, failure aggregation, and
frame-aware teardown ownership.

## Phase Objective

Land the cluster-lifecycle and resource contracts in `hostbootstrap-core` (see
[development_plan_standards.md § O](development_plan_standards.md)). `hostbootstrap` verifies the host
has capacity for the budget declared in `resources` under the substrate-specific reserve policy and
cordons it — on Apple by sizing a dedicated
per-project VM wall on Apple, on Linux by applying kind node resource limits — drives kind/Helm cluster
lifecycle, never enumerates the plan's `.data` path for removal, and distinguishes the production cluster
profile (fixed name / `.data` path) from the run-named test profile. Those names are not exclusive
ownership. Sprint 5.7 owns the identity-bearing backend receipts; Sprint 10.9 owns lifecycle-mode/profile
opening over Sprint 15.9's root authority.
What non-enumeration and the landed host-root carry do and do not guarantee is
[durable_state](../documents/architecture/durable_state.md).

## Remaining Work

**Durable read-back — active (Sprint 5.6).** Canonical direct-host root admission is complete. Run the
command-level write → destroy → up → read assertion once the native registry route is healthy.

**Storage/ownership reconciliation — blocked (Sprint 5.7).** Implement typed backend reconcile outcomes,
exclusive ownership, conditional cleanup, provider storage enforcement, and backend-level durable
preservation. The later integration tranche reruns Sprint 5.6's command proof through the typed plan.

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
  owned by the independently supplied project teardown hook; an attempted local cleanup still fails
  closed. Phase 16.6 owns deriving the reverse traversal from the forward lifecycle plan.
- **Landed (static):** listed-but-unhealthy cluster recovery requires the Kind delete step to succeed
  before recreation; unresolved or non-zero deletion fails closed.
- **Remaining (real-run-gated):** on a **native Linux CPU** host, run the Incus-backed lane through
  in-cluster daemon `ClusterIP` connectivity and the C++ worker; the five-case/two-variant matrix must
  report `10/10`.
- **Remaining (real-run-gated):** on a **native Linux GPU** host, run the direct `nvkind` lane through the
  CUDA daemon/worker, browser Add assertion, and durable readback; the five-case/two-variant matrix must
  report `10/10`.

Validation: unit tests for cluster profile/exposure rendering, integration tests for Linux CPU and Linux
GPU daemon connectivity, and the browser e2e add workflow through the web service.

Dated static validation evidence (2026-07-20): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` passed from `core/` with 374 tests; the demo `-Werror` build and test run passed with
89 demo tests plus the embedded 374 core tests. Coverage includes fail-closed placement-specific cluster
configs, service/NodePort separation, official NVIDIA runtime probing, pre-mutation device-plugin
idempotence, install/readiness/allocatable classification, aggregate teardown failure propagation with
`.data` preservation, frame-aware command-level Kind ownership, fail-closed unhealthy-cluster deletion
before recreation, the worker label, two-node cordon splitting, direct-chain CUDA
image/`--gpus=all` handoff, daemon GPU requests, and the implemented browser Add assertion. The native
Linux CPU Incus/ClusterIP/C++ and native Linux GPU direct-nvkind/CUDA/browser gates remain open. Each
five-case/two-variant lane must report `10/10`; the latest completed live gate remains the historical
pre-accelerator `6/6` result. The Phase 3 closure remains its historical 359-test snapshot.

**Previously closed 2026-07-05 — cross-substrate cluster readiness + idempotency:**

- **Node/CNI readiness gate — landed.** `clusterCreate` now runs `waitNodesReady`
  (`kubectl wait --for=condition=Ready node --all --timeout=30s`, bounded-retry × 10 with a 3 s backoff,
  fail-closed) **after** `kind create` (`--wait 0s`) and the cordon and **before** it returns, so the
  chain's first `kubectl apply` / Helm install is not scheduled before an initial node/API/CNI-ready
  observation (`HostBootstrap.Cluster.Lifecycle.clusterCreate`). This orders the call graph; it does not
  guarantee an external control plane cannot fail after observation.
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
  `deploy-kind` / `deploy-chart` step kinds. Current `project up` performs forward recursive descent;
  current teardown performs owning-current-frame Kind cleanup plus the independently supplied
  `psTeardown` hook, not a child-first reverse traversal projected from the chain. Phase 16.6 owns that
  derived reverse plan (§ Y). The pure `resolvePlan`, `teardown`, `statusReport`, and cordon cores remain
  the implementation those steps call; they are not rewritten.
- Split bring-down into two distinct capabilities: `project down` stops provider VMs but deletes kind
  clusters at the frame that owns `deploy-kind`, while preserving durable state; `project destroy` stops
  then deletes everything spun up. A root frame skips core Kind lookup when the cluster belongs to a
  nested VM/project-container frame and delegates that nested cleanup to the independently supplied
  project teardown hook. The old `cluster down` collapsed lifecycle framing; an owning cluster frame uses
  delete-on-down because kind has no reliable stop/restart contract.
- The never-delete-`.data` invariant is preserved across both `project down` and `project destroy`: the
  plan's `.data` path is never placed in any removal set (§ Y). The demo now creates `.data` at the host
  project root and carries it through the provider share/guest alias, project-container mount, Kind node,
  and pod. That transport is implemented, but the write→destroy→up→read-back proof and exclusive
  ownership remain open ([durable_state](../documents/architecture/durable_state.md)).
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

Land `HostBootstrap.Cluster.Cordon`: verify the resolved substrate capacity can admit the `resources`
budget and cordon it to the project.

#### Deliverables

- Budget verification reading `resources {cpu, memory, storage}` and checking the substrate's resolved
  CPU/memory/storage capacity under the applicable host-reserve policy.
- Apple cordoning: **derive** the sizing for the dedicated VM wall from the budget.
- Linux cordoning: **derive** kind node resource limits from the budget.

The pure cordon derives the args; applying them happens through the project binary's lifecycle and host
provider flows.

#### Validation

- `CordonSpec` asserts a budget exceeding resolved capacity fails fast naming the over-committed
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

#### Historical Command Surface

The following command spellings describe the surface at this sprint's original closure. They were later
removed; the retained lifecycle functions now run only under `project up|down|destroy`.

- `hostbootstrap cluster up` — attempt reconcile-to-running within the cordoned budget; the historical
  implementation did not provide receipt-preserving idempotence.
- `hostbootstrap cluster down` — tear the cluster down; the removal set is empty, so no path is removed.
- `hostbootstrap cluster delete` — thorough teardown of derived state; still never enumerates `.data`.

#### Deliverables

- kind/Helm lifecycle driving cluster creation, Helm release management, and teardown.
- The never-delete-`.data` invariant enforced on both `down` and `delete`.
- A forgeable `ClusterProfile` distinguishing production (fixed name / `.data` path) from test
  (per-case-named paths). It provides naming separation only; Sprints 9.10/10.9 replace it with opaque
  scope/profile authority, while Sprint 5.7 supplies the receipt-aware backend operations that authority
  will enter.

#### Validation

- `LifecycleSpec` asserts `teardown Down` / `teardown Delete` never place `.data` in the removal set
  (for both profiles), and that the production and test profiles resolve distinct cluster names and
  host paths. At the historical closure, `cabal test` passed and `hostbootstrap cluster --help` listed
  `up`/`down`/`delete`.

#### Remaining Work

None within Sprint 5.2's historical scope. The pure lifecycle/teardown cores and
never-delete-`.data` invariant carry forward; Phase 16's landed command interpreter owns their current
`project up|down|destroy` surface, while open Sprint 16.6 owns the replacement typed recursive
interpreter. The container-frame apply was real-run-validated by the demo.

### Sprint 5.3: Read-only `cluster status` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `system-components.md`

#### Objective

Historical delivery record: the standalone `cluster status` verb was later removed. The pure status
renderer remains, and current read-only lifecycle/context inspection is exposed through the fixed
`context` surface.

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

Historical delivery record: the standalone `cluster up` spelling was later removed. Its fail-closed
Kind/Helm behavior is retained as lifecycle functions invoked by the `deploy-kind`/`deploy-chart` plan
steps under `project up`.

Make `cluster up` fail-closed on its helm/kind steps, and run the lifecycle in the in-container path (the
kube tools are baked into the base image, not host tools — § L).

#### Deliverables

- `cluster up` uses `requireStep` for `kind create cluster` and `helm upgrade --install`: a non-zero exit
  or an unresolved tool `die`s, so a broken deploy is loud and a lifting parent process sees a non-zero
  exit. Listed-but-unhealthy cluster recovery also requires successful Kind deletion before recreate.
  Teardown attempts every intended Kind and derived-path cleanup, aggregates failures, and reports the
  aggregate after all cleanup has been attempted.
- `project down|destroy` runs that core Kind teardown only in the current frame that owns the chain's
  `deploy-kind` step. Nested clusters are left to the independently supplied project teardown hook, so
  expected host-side absence of container-only Kind is not misreported as a cleanup failure. Phase 16.6
  replaces that hook with reverse cleanup derived from the unified lifecycle plan.
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
nested cluster teardown remains in the independently supplied project hook until Phase 16.6 derives it
from the lifecycle plan.

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
and the C++ worker at `10/10`, and a native Linux GPU direct-`nvkind` lane proving the CUDA-base,
one-GPU daemon pod, CUDA worker, browser e2e Add workflow, and durable readback at `10/10`. The Windows GPU
host-daemon-through-the-local-only-NodePort path is exercised by the decoupled Windows/WSL2 durable gate
(Phase 13). No WSL2 result is represented as native Linux. No qualifying native-Linux `8/8` result is
recorded yet, so the
historical `6/6` remains evidence only for the pre-accelerator matrix. No implementation or static-test
work remains in this sprint.

### Sprint 5.6: Host-durable project state [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`, `demo/kind.yaml`, `demo/chart/`
**Docs to update**: `documents/architecture/durable_state.md`, `documents/architecture/readiness.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Finish and validate the host-durable `.data` contract. The host root creation, provider share, alias, and
VM→container→kind→pod carry have landed; the remaining closure criterion is a dedicated
write→destroy→up→read-back proof.

#### Deliverables

- A durable-root contract that resolves to a **host** path regardless of which frame owns the cluster
  step, consuming the share primitive from phase-11 Sprint 11.8.
- The durable root carried across every boundary a nested chain crosses: VM → project container
  (a `Mount` on the container launch), container → kind node (`extraMounts` in the kind config, which
  accompanies its port mappings), kind node → pod (a host-backed volume in the chart).
- A create-on-`up` path, so the root exists rather than being vacuously preserved.
- The teardown status line stops reporting `preserved` for a path it never inspected.

#### Validation

- `cabal test all` from `core/` — the existing `LifecycleSpec` on-disk teardown cases continue to pass
  unchanged; new cases cover durable-root resolution across frames.
- Real-run gate (§ C), jointly with phase-11 Sprint 11.8: write state through the running stack, run
  `project destroy`, run `project up`, and read the same state back.

#### Remaining Work

The durable-root carry (VM → project container → kind node → web pod) and the **host-side** provider share
(phase-11 Sprint 11.8) are implemented and statically gated. Its **share/alias mechanism is historically
validated** by the live
Windows/WSL2 `test run all` **`8/8`** (2026-07-23): the recast pure, readiness-gated `AliasState` alias
(phase-11 Sprint 11.9) links cleanly on both variants
(`vm up: linked durable alias /var/tmp/hostbootstrap-demo-data -> /mnt/c/…/demo/.data`) — the ungated
`set -eu` step that collapsed `0/8` is gone — and a residual failure is now legible (phase-10 Sprint 10.8).
**Remaining (real-run-gated, § C):** the end-to-end durable-root **read-back** (write a marker through the
running service → `project destroy` → `project up` → read the same marker from the host-backed root) is
implemented as the `durable-readback` harness case. Static validation passed on 2026-07-25 with 100 demo
tests. Sprint 5.6.1 now supplies the canonical absolute direct-host bind. A native Linux GPU rerun passed
that boundary, created and cordoned nvkind, and proved allocatable GPU capacity, then failed while
finalizing the pushed image manifest because the in-cluster registry returned `unknown error`. Sprint
13.18 owns that registry/MinIO integration failure. This sprint stays Active until the read-back case
passes; no governed document may yet describe host-durable `.data` as end-to-end validated (§ J).

That result is the handoff prerequisite for Phase 15.9 to promote the descriptive `DurableStore` label
into opaque mutation authority. This sprint does not own that later command-gate change and can close
when the durability proof itself passes.

### Sprint 5.6.1: Canonical project-root authority and durable projections [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectRoot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/cluster_lifecycle.md`, `legacy-tracking-for-deletion.md`

#### Objective

Resolve descriptive `sourceRoot` once into opaque canonical root authority and derive every
substrate-specific durable path from that same identity, so direct-host execution never substitutes a
guest compatibility alias for the actual host directory.

#### Deliverables

- Root-config admission resolves a relative `sourceRoot` against the stable project-home/config-ownership
  anchor, not `cwd` or the executable's sibling `.build` directory, verifies the project tree, and
  canonicalizes it once inside a rank-2 `CanonicalProjectRoot scope rootId` bracket.
- The current lifecycle admission seam consumes that authority without rewriting `BinaryContext` and
  derives the Production host `.data` projection under the same `scope`/`rootId`. The final opaque
  `ProjectPlan`, Harness `.test_data/<runId>` selection, and its complete guest/container/kind/pod
  projection family remain owned by Sprints 10.9, 16.6, and 19.8; this foundational sprint is deliberately
  not a hidden prerequisite of those already-declared blockers.
- The direct-host Docker adapter binds the canonical absolute host durable path. Provider lanes may use
  a protected guest alias as a provider-local projection only; that alias is never host-root authority.
- Raw host/guest/container path interchange and the retired direct-host alias compatibility description
  are entered in the deletion ledger with their remaining owning consumers.

#### Validation

- Unit/property tests prove identical config bytes resolve independently of process `cwd`, while a
  missing, wrong, escaping, replaced, or wrong-kind root fails before plan construction.
- Compile-fail/API tests prove raw `FilePath`, guest aliases, container paths, and a root from another
  `scope`/`rootId` cannot enter the host-bind adapter or plan.
- Pure frame-context tests show direct Linux uses the canonical host `.data` path while WSL2, Incus, and
  Lima use only their provider-guest projection.
- The Sprint 5.6 native direct-Linux durable-readback gate reaches Docker with an absolute nonsymlink
  host bind before Sprint 5.6 resumes its write→destroy→up→readback validation.

#### Remaining Work

Completed 2026-07-25. Config admission resolves descriptive `sourceRoot` against the config-owned project
anchor without consulting caller `cwd`, rejects missing, wrong-kind, escaping, and redirected roots, and
yields a private rank-2 `CanonicalProjectRoot scope rootId`. It does not materialize the canonical path
back into `BinaryContext`. Root-aware lifecycle frame and teardown seams carry the authority, and the
direct-host adapter accepts only a `CanonicalHostPath` with the same `scope`/`rootId`; raw `FilePath` and
cross-root projections fail to compile. Direct Linux binds canonical `<project>/.data`; only VM-backed
lanes retain `/var/tmp/hostbootstrap-demo-data` as a provider-guest projection.

The native Linux GPU rerun reached Docker with the absolute nonsymlink bind, created nvkind, cordoned
both nodes, and proved `nvidia.com/gpu` allocatable after the device-plugin and CUDA workload were moved
onto nvkind's `nvidia` runtime class. It then failed later while finalizing the pushed image manifest:
all layers uploaded to `localhost:30500/library/hostbootstrap-demo`, but the registry returned
`unknown error`. That registry/MinIO failure blocks the command-level durable-readback case and is
tracked with the demo registry/provenance work in Sprint 13.18.

Validation passed on 2026-07-25: the focused seven-case `ProjectRootSpec`, the full **386-test**
`hostbootstrap-core` suite, and the full **100-test** demo suite all passed under `-Werror`. The final
scope-/profile-indexed `ProjectPlan` consumes this closed authority in its owning later sprints; it does
not reopen this root-admission contract.

#### Remaining Work

None.

### Sprint 5.7: Storage cordon and ownership-aware reconciliation [Active]

**Status**: Active
**Blocked by**: None (Sprint 9.10 and Sprint 11.10's alias/ownership primitive are landed)
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/engineering/applied_cordon.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Turn durable storage and cluster mutation into typed, ownership-aware **backend reconciliation**
instead of path conventions and optimistic create/delete behavior. This sprint supplies the
provider/storage primitives and receipts consumed by the later run-lease/handoff/recursive-plan tranche;
it does not construct lifecycle profiles, root/test authority, or the final `ProjectPlan`.

#### Deliverables

- Apply the declared storage ceiling on every supported provider and report unsupported enforcement as a
  typed outcome, never as silent success.
- Have cluster/storage reconcilers return `Either ReconcileError ReconcileResult`:
  `ManagedResult` carries a `Managed` handle, receipt, and `Changed (Created | Repaired | Adopted)` or
  `Unchanged`; `ForeignResult` carries only an `Unmanaged` handle and observation. `Conflict`,
  `SafetyRefusal`, `Unsupported`, and `Failure` remain distinct. A foreign handle cannot authorize
  mutation or cleanup; explicit adoption requires matching opaque authority.
- Expose the provider/storage reconcilers only over Phase 9's opaque resource identity, generation,
  classification, and receipt inputs. Do not mint `LifecycleProfile`, root/test authority, or
  `ProjectPlan` here: Sprint 10.9 owns Production/Harness mode/profile construction, and the coordinated
  10.9/15.9/16.6 tranche binds these backend operations to the final plan and command authority.
- Hold the four § EE ownership clauses before mutating a cluster, durable root, or global cordon, and
  require the resulting receipt for cleanup: an OS-released exclusive lock across the bracket, a durable
  origin record naming exact bytes or absence before the first write, binding to the object's stable
  kernel identity, and release conditioned on re-observing that identity. Provider CAS/create-if-absent
  with immutable generation identity satisfies the same clauses at a provider backend. Bare exclusive
  create/rename or compare-then-unlink binds a pathname and satisfies none of them; a backend that
  cannot hold a clause reports `Unsupported`. A conflict or safety refusal never tears down
  operator-owned state. See
  [ownership_invariant](../documents/architecture/ownership_invariant.md). **Restated 2026-07-27:** this
  bullet previously required a namespace protected from same-privilege replacement — a guarantee no
  substrate supplies.
- Make `spStop` release the WSL2 wall so `project down` means the same thing on every substrate: restore
  `.wslconfig` **first**, then run `wsl --shutdown`. The order matters — the shared utility VM re-reads
  the file on its next cold boot, so restoring after the shutdown would republish the managed body. The
  shutdown is the same disclosed global side effect already performed on bring-up, and
  `discloseWslShutdown` must be wired into the `down` path as it already is for `up`. Depends on Sprint
  9.11's finite idle timeouts: without them the utility VM stays pinned between runs regardless. Lima
  and Incus already release on stop, so no change is needed there.
- At the backend-contract level, prove that the host-owned durable root survives provider
  destroy/recreate and that conditional cleanup rejects a replaced generation. Sprint 5.6 retains the
  existing command-level write → `project destroy` → `project up` → read gate; the coordinated
  integration tranche later reruns it through the typed plan.
- Expose storage-wall, reservation, and conditional-cleanup backend operations over already validated
  budget/exposure inputs and return the exact typed result/receipt. Each strong backend operation must
  accept the conditional target/dependency version sealed by the later
  `PreparedOperation`/`PreparedPreconditions` pair and reject or deduplicate a mismatch; a backend that
  cannot bind its effect to that prepared version reports `Unsupported`. This sprint does not assemble the
  workload set, issue a plan mutation permit, or render Kubernetes manifests; the coordinated
  10.9/15.9/16.6 tranche owns generic plan/permit integration and Sprint 13.18 owns the demo's complete
  workload-to-manifest wiring.
- Replace current same-name kind adoption/deletion with total ownership classification: a healthy
  unowned cluster is `ForeignResult`; an unhealthy/unverifiable same-name cluster is `Conflict`, never
  automatically deleted. Supply backend operations that retain loopback binding and accept only an
  already authorized exposure/credential input. Secret generation, endpoint policy selection, and
  registry/web/MinIO manifest wiring remain Sprint 13.18 work over Sprints 15.9 and 19.7.

#### Validation

- Pure tests cover created/repaired/adopted `Changed`, managed `Unchanged`, `ForeignResult`, explicit
  adoption, `Conflict`, `SafetyRefusal`, `Unsupported`, `Failure`, and storage-limit argument generation.
- Backend tests prove storage-wall inputs produce the expected provider operations/results and that the
  default exposure primitive binds loopback; they do not claim config-to-plan-to-manifest agreement.
  Sprint 13.18 owns that final agreement and the over-budget no-permit assertion.
- Compile-time negative fixtures prove a foreign/unmanaged handle or a receipt for another
  resource/generation cannot enter a provider/storage mutation or cleanup.
- Backend race fixtures prove a dependency/target version replacement after prepare cannot execute as
  though readiness were current; the conditional operation either applies to the exact prepared version,
  returns a typed mismatch for journal recovery, or is `Unsupported`.
- Failure-injection tests prove a foreign path/cluster is retained and owned partial state is unwound.
- Native provider real runs verify the applied storage wall and backend-level durable preservation;
  Sprint 5.6 and the later integration tranche own command/plan-level read-back. Accelerator-only live
  lanes remain separately owned by Sprint 5.5.

#### Remaining Work

**Delivered 2026-07-27 (total cluster ownership classification):**
`HostBootstrap.Cluster.Reconcile` expresses the § EE total ownership classification for the kind cluster
over Phase 9's opaque resource/receipt algebra (the same shape as the guest-alias backend).
`settleClusterReconcile` returns `Either ReconcileError ReconcileResult`: an absent cluster created is
`Changed Created`; a healthy same-named cluster with a matching committed proof is `Unchanged`, and
**without** proof is a `ForeignResult` (never adopted); an **unhealthy or unverifiable** same-named
cluster is a structured `Conflict` that is **never auto-deleted** — the explicit replacement for the
`ensureCluster` "delete and recreate an unhealthy cluster" behavior; and a probe fault is a typed
`Failure`, never a false absence (§ CC). `withPreparedClusterCleanup` requires a `Managed` handle and a
matching receipt, and `settleClusterCleanup` refuses to remove a replacement carrying a different
generation. `ClusterReconcileSpec` covers all seven branches, and two compile-fail fixtures
(`ForeignClusterCleanup`, `CrossClusterReceipt`) prove an unmanaged handle or a cross-resource receipt
cannot enter cleanup. `spStop` already releases the WSL2 wall (see Sprint 11.10). Core gate: **503/503**
under `-Werror` on Linux.

**Still open (this sprint):**

- the **storage-wall backend operation**: apply the declared storage ceiling on every supported provider
  and return a typed `Unsupported` where enforcement is impossible (bare Linux has no storage quota,
  § O/§ 9.4), over already-validated budget inputs — not silent success;
- the **IO backend that holds the four clauses for the cluster** (produces the `ClusterObservation`s
  while holding a `flock`/provider-CAS lock, an origin record, and identity binding), analogous to the
  guest-alias `GuestExec` backend, plus the loopback-bound exposure/credential backend operation;
- replace the imperative `ensureCluster` delete-recreate and same-name adoption with the classification
  above — the **command/plan-level wiring** is the coordinated 10.9/15.9/16.6 tranche's to consume
  (Sprint 5.6 retains the command-level durable-readback gate meanwhile);
- native provider real runs proving the applied storage wall and backend-level durable preservation.

Profile/root/test authority and `ProjectPlan` integration remain explicitly outside this sprint in the
coordinated 10.9/15.9/16.6 tranche, avoiding a dependency back into this foundation. Sprint 5.5 remains
independently Active for the unavailable native accelerator lanes; neither lane can close this phase by
proxy for the other.

### Sprint 5.8: Applied per-project Apple provider budget [Done]

**Status**: Done
**Blocked by**: None (Sprint 9.10 is complete)
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/prerequisites.md`, `documents/engineering/applied_cordon.md`,
`documents/engineering/ensure_reconcilers.md`,
`documents/architecture/hostbootstrap_core_library.md`, `system-components.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Turn the existing pure Colima sizing arguments into the per-project Apple Docker-provider wall instead of
starting an unsized shared default profile.

#### Deliverables

- Derive a stable project-specific Colima profile identity from the validated binary context.
- Reconcile that profile with the declared CPU, memory, and storage budget; an already running profile
  with a conflicting wall is a structured conflict, not silently accepted.
- Route direct Apple Docker operations through the reconciled profile and its socket/context, while the
  pristine demo's separate Lima wall remains unchanged.
- Return typed applied/unchanged/repaired/conflict/failure observations whose settlement retains the
  matching live wall authority and receipt. No bare `colima start` default-profile fallback satisfies
  the contract.

#### Validation

- Pure argv tests bind profile, CPU, memory, and disk to one validated budget and reject omissions or
  conflicting existing settings.
- A concurrency test proves two project invocations converge on one owned profile or report structured
  conflict; an unrelated profile is never mutated.
- An Apple real run verifies the observed VM limits and Docker endpoint match the project config, then
  reruns idempotently and tears down only the owned profile.

#### Remaining Work

None in Sprint 5.8. Completed 2026-07-26:

- `HostBootstrap.Ensure.Colima` now derives an opaque plan-bound profile from matching validated
  project/binary identity, rejects `default`, consumes only the Phase 9 exact
  wall/partition/reservation, parses `colima list --json` JSONL, and refuses incompatible same-name
  CPU/memory/disk/runtime state.
- The prepared call uses current Colima `--cpus`, fixes the runtime to Docker, and passes
  `--activate=false`. `runColimaDocker` always adds the stable `colima-<project>` named context; it never
  changes the process-global active context. The old config-free Colima reconciler is absent from
  `allReconcilers`.
- A failed competing start is re-observed: exact running state converges to unchanged, incompatible
  state becomes a structured conflict, and unresolved state remains a typed retryable failure. Empty or
  unreadable machine identity returns a typed failure and cannot mint epoch-zero authority.
- Focused `ColimaSpec`, `CordonSpec`, and `EnsureSpec` coverage validates exact prepared argv, disjoint
  identities, named-context routing, JSONL observations, absent/running/stopped classification,
  conflict refusal, and removal of the default-profile route. The `hostbootstrap-core-test` suite passed
  all 448 tests under `-Werror` on 2026-07-26; the demo workspace passed all 106 demo tests and its
  embedded 448-test core suite under the same gate. `DocValidatorSpec` and `git diff --check` passed.
- Two Apple gates used disposable profiles only. The ordinary gate observed exactly 2 CPU, 4 GiB memory,
  20 GiB disk, Docker runtime, a reachable named-context Docker daemon, an unchanged active `colima`
  context, and an idempotent second start. The concurrent absent-profile gate produced one successful
  creator and one backend conflict, converged on that same exact running wall, and served Docker through
  only its named context. Both disposable profiles and contexts were deleted; the pre-existing
  `default` and `incus` profiles were not mutated.

#### Scope Disposition

Sprint 5.8 owns exact project-profile acquisition and the retained live wall authority/receipt.
Generation-conditional `down`/`destroy` cannot be implemented safely from a Colima name check: a name is
not an object identity, so clauses 3 and 4 are unmet. Sprint 5.7
already owns receipt-guarded provider cleanup and must either supply an identity-bound conditional
operation or
return `Unsupported`; Sprint 16.6 owns consuming that result from the recursive reverse plan. This is a
narrow dependency assignment, not a claim that name-only deletion is safe.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/durable_state.md` - the canonical home of the never-delete-`.data` invariant:
  the removal-set guarantee, frame-relativity, and the Sprint 5.6 durable-root contract.
- `documents/architecture/readiness.md` - the readiness discipline gating the durable-root's mount/alias
  steps (phase-11 Sprint 11.9) and its legible-failure contract.

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
