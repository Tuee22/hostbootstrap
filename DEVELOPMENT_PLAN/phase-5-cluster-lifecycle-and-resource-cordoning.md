# Phase 5: Cluster Lifecycle and Resource Cordoning

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Land kind/Helm cluster-lifecycle semantics, resource-budget verification and
> cordoning (VM wall on Apple, kind node limits on Linux), the never-delete-`.data`
> invariant, and the production-vs-test cluster profile.

## Phase Status

**Status**: Done

**Reopened then closed (2026-07-05, cross-substrate reliability hardening).** The demo real-run gate (Sprint
13.16) surfaced cluster-lifecycle readiness/idempotency gaps in this phase's scope: `kind create` (default
`--wait 0s`) is followed by an immediate `kubectl apply` with no node-Ready/CNI gate; `clusterCreate`
trusts `kind get clusters` with no health check (a stopped in-VM cluster reads as running); and the
`down`-deletes-kind / `up`-recreates contract does not hold for the VM-nested demo cluster (`down` only
stops the VM). The fixes landed (see `## Remaining Work`) and **closed 2026-07-05** by a live Windows/WSL2
`hostbootstrap-demo test run all` reporting **`test report: 6/6 passed`** across both message variants — the
`cluster up: nodes Ready for hostbootstrap-demo` gate fired on each of the two bring-ups before the first
apply, then `project destroy` tore down with host `.data` preserved.

The cluster lifecycle is now reached **only** as `deploy-kind` / `deploy-chart` chain steps under
`project up` (the flat `cluster` verb group is removed; read-only liveness moved under `context`), and the
real-run gate is **met (2026-06-18)**: a live `project up` on Incus/Linux brought the cordoned kind cluster
up in the container frame (`clusterCreate` preflight + `kind create` + `kind export kubeconfig` + the Linux
cordon, then the registry + web charts), and `project down` / `project destroy` tore it down with host `.data`
preserved (§ O). The pure cores below are unchanged and unit-tested.

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
`project` lifecycle interpreter (Done), and the only remaining item is the real-run-gated container-frame
apply — wiring the cluster bring-up as a real `deploy-kind` / `deploy-chart` step action and the recursive
`project down` / `project destroy` teardown that issues the stop/delete to the live VM, validated by a real
`project up` run (owned with [Phase 16](phase-16-project-lifecycle-command.md)).

## Phase Objective

Land the cluster-lifecycle and resource contracts in `hostbootstrap-core` (see
[development_plan_standards.md § O](development_plan_standards.md)). `hostbootstrap` verifies the host
has the spare budget declared in `resources` and cordons it — on Apple by sizing a dedicated
per-project VM wall on Apple, on Linux by applying kind node resource limits — drives kind/Helm cluster
lifecycle, never deletes host `.data`, and distinguishes the production cluster profile (fixed name /
`.data` path) from the test profile (per-case isolated paths).

## Remaining Work

**Reopened 2026-07-05 — cross-substrate cluster readiness + idempotency. Code landed + code-check-validated
2026-07-05; real-run-gated (§ C) closure pending:**

- **Node/CNI readiness gate — landed.** `clusterCreate` now runs `waitNodesReady`
  (`kubectl wait --for=condition=Ready node --all --timeout=30s`, bounded-retry × 10 with a 3 s backoff,
  fail-closed) **after** `kind create` (`--wait 0s`) and the cordon and **before** it returns, so the chain's
  first `kubectl apply` / Helm install cannot race the API server or CNI on a busy host
  (`HostBootstrap.Cluster.Lifecycle.clusterCreate`).
- **Health-check-and-recreate — landed.** `clusterCreate` no longer trusts `kind get clusters`: a listed
  cluster is health-probed by `ensureCluster` → `clusterHealthy` (export kubeconfig, then
  `kubectl get nodes`; the pure classifier `clusterHealthyFromProbe` is unit-tested in `LifecycleSpec`), and
  a listed-but-unhealthy cluster (stopped containers → connection refused) is `kind delete`-d and recreated.
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
(`stopVMArgs` for Incus and Lima, unit-tested in `IncusSpec` / `LimaSpec`). Remaining
(**real-run-gated**, § C): wire the cluster bring-up/teardown as real `deploy-kind` / `deploy-chart` /
teardown step actions under `project up` / `project down` / `project destroy` (the recursive teardown
issuing stop versus delete to the live VM), the `.data` invariant preserved — validated by a real
`project up` run, owned with [Phase 16](phase-16-project-lifecycle-command.md).

Specifically:

- The standalone `cluster up|down|delete|status` verb group is dissolved; cluster bring-up becomes the
  `deploy-kind` / `deploy-chart` step kinds, and teardown becomes the descent-then-ascent stop/delete the
  `project` lifecycle interpreter performs over the chain (§ Y). The pure `resolvePlan`, `teardown`,
  `statusReport`, and cordon cores remain the implementation those steps call; they are not rewritten.
- Split bring-down into two distinct capabilities: `project down` stops provider VMs but deletes kind
  clusters while preserving durable state, and `project destroy` stops then deletes everything spun up.
  The old `cluster down` collapsed lifecycle framing; the current cluster frame uses delete-on-down
  because kind has no reliable stop/restart contract.
- The never-delete-`.data` invariant is preserved across both `project down` and `project destroy`; the
  durable host `.data` path is never placed in any removal set (§ O).
- The `project` lifecycle command, its step interpreters, and the stop-without-delete capability **ship**,
  and the flat `cluster` verb group is **removed** (§ Sprint 5.2). Phase 16 owns the interpreter (Done);
  the only remaining item is the real-run-gated container-frame apply, owned by
  [Phase 16](phase-16-project-lifecycle-command.md); the dissolved `cluster` verbs are recorded under
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
- `hostbootstrap cluster down` — tear the cluster down; preserve host `.data`.
- `hostbootstrap cluster delete` — thorough teardown of derived state; still never deletes `.data`.

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

The pure lifecycle/teardown cores (`resolvePlan`, `teardown`, the `ClusterProfile` distinction) and the
never-delete-`.data` invariant built here are still valid and carry forward; what changes is the
command-surface contract they hang off.

- Re-express the kind/Helm bring-up as the `deploy-kind` / `deploy-chart` chain steps under `project up`,
  and the teardown as the `project` lifecycle interpreter's descent-then-ascent over the chain, replacing
  the standalone `cluster up`/`down`/`delete` verb group (§ Y).
- Split the single `cluster down` lifecycle into `project down` (delete the kind cluster while preserving
  durable state; VM frames stop without delete) and `project destroy` (stop then delete everything spun
  up). The never-delete-`.data` invariant holds across both, with `.data` never in any removal set (§ O).
- **Done (code-check):** the `project` lifecycle interpreter ships and the flat `cluster up|down|delete`
  verbs are removed from the core tree (`coreCommandNames`). The teardown split is implemented and
  **real-run-validated** — `project down` tears down kind compute and stops the VM, `project destroy`
  deletes, both preserving host `.data`
  (§ O). The kind/Helm bring-up is re-expressed as the demo's `deploy-kind` (`clusterCreate`) /
  `deploy-chart` (`deployChart`) container-frame chain steps under `project up` (the core `clusterUp` split
  into exported `clusterCreate` + `deployChart`). **Remaining (real-run-gated, § C):** the container-frame
  apply that runs those steps end-to-end — owned by the demo's container-frame real run
  ([Phase 16](phase-16-project-lifecycle-command.md) increment 3, [Phase 13](phase-13-hostbootstrap-demo.md)).

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

The pure `statusReport` renderer and the `clusterStatus` driver built here are still valid and carry
forward; what changes is where their read-only output surfaces.

- The standalone read-only `cluster status` verb is dissolved: liveness/`.data`-path introspection moves
  under the read-only `context` command, which renders the global lift composition with the current frame
  highlighted (§ Z). `cluster status` performed no mutation, so this is a relocation of the read-only
  surface, not a behavior change in the renderer.
- The `context` introspection command is implemented and the code no longer exposes a standalone
  `cluster status` verb. That relocation is owned by [Phase 16](phase-16-project-lifecycle-command.md)
  (with the introspection contract from [Phase 15](phase-15-binary-context-config.md)); the dissolved
  `cluster status` verb is recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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
  exit. `reportStep` is retained only for best-effort teardown.
- The lifecycle is invoked in the project container via the self-reference lift (`HostBootstrap.Lift`,
  phase-11), so `helm`/`kind` resolve on the container `$PATH` rather than the host.

#### Validation

- The pure `LifecycleSpec` is unchanged; the fail-closed behaviour and the in-container run are exercised
  in the [demo](phase-13-hostbootstrap-demo.md)'s real run. `cabal test` passes.

#### Remaining Work

The fail-closed `requireStep` discipline (a non-zero kind/Helm exit or unresolved tool `die`s, with
`reportStep` retained for best-effort teardown) and the in-container run via the self-reference lift are
both still valid and carry forward unchanged into the step interpreters; what changes is the verb that
hangs off them.

- The fail-closed bring-up moves from the `cluster up` verb into the `deploy-kind` / `deploy-chart` chain
  steps interpreted by `project up` (§ Y). Inside `project up`'s recursive interpretation, the steps run in
  the in-container frame reached by the self-reference lift (§ U), so `helm` / `kind` still resolve on the
  container `$PATH`. Best-effort teardown becomes the `project down` / `project destroy` descent.
- **Done (code-check):** the fail-closed bring-up now hangs off the `deploy-kind` / `deploy-chart`
  container-frame chain steps under `project up` (the `requireStep` discipline in `clusterCreate` /
  `deployChart` is unchanged), reached by the recursive interpreter's `docker run … project up` handoff into
  the `vm-project-container-2` frame, so `helm` / `kind` resolve on the container `$PATH`. The flat
  `cluster up` verb is removed. **Remaining (real-run-gated, § C):** the live in-container run exercising the
  fail-closed steps end-to-end, owned by the [demo](phase-13-hostbootstrap-demo.md)'s container-frame real
  run ([Phase 16](phase-16-project-lifecycle-command.md) increment 3).

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` - budget verification, Colima per-project VM sizing
  on Apple, kind cordoning on Linux.
- `documents/engineering/cluster_lifecycle.md` - kind/Helm semantics, the never-delete-`.data`
  invariant, the production-vs-test profile.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.*` rows and the resource-cordoning
  section.
- WSL2 stop-without-delete on ascent (`wsl --terminate` without `wsl --unregister`) and WSL2-VM-boundary
  cordoning (the `.wslconfig` + vhdx wall) are owned by
  [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)'s Windows WSL2 host-provider sprint —
  the Windows peer of the Incus/Lima stop-without-delete and VM cordon carried here.
