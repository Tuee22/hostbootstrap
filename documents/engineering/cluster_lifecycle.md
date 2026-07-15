# Cluster Lifecycle

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [resource_budgeting](resource_budgeting.md), [dhall_topology](dhall_topology.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [testing](testing.md)

> **Purpose**: Define the kind/Helm cluster-lifecycle semantics `hostbootstrap-core` provides as
> chain steps under `project up`/`project down`/`project destroy`, including kind
> teardown-on-down with durable-state preservation, the never-delete-`.data` invariant, and the
> production-versus-test profile concept.

## TL;DR

- Cluster bring-up and teardown are **chain steps**. The core ships `deploy-kind`-class step kinds
  that the recursive `project up`/`project down`/`project destroy` interpreter runs at the container
  frame, where the chain bottoms out into `kubectl`/`helm`/`kind` leaves.
- `project up` brings the cluster to *running* (idempotent, fail-closed). At the kind-cluster frame,
  `project down` deletes the kind cluster while preserving durable state. `project destroy` also deletes
  the kind cluster and its compute.
- The lifecycle never deletes a cluster's `.data` directory: persistent state survives bring-up,
  stop, and teardown.
- A cluster runs under one of two profiles. The production profile uses `.data` and a fixed cluster
  name; the test profile uses `.test_data` and a test-scoped cluster name.
- The chain `[Step]` value is the project; cluster steps interleave with host-management steps in
  the same chain. The model itself is owned by
  [composition_methodology](../architecture/composition_methodology.md); this doc defers to it and
  describes the cluster-specific steps.

## Cluster Steps In The Chain

The chain is the project: `chain :: cfg -> [Step]` is one ordered representation the recursive
interpreter walks (see [composition_methodology](../architecture/composition_methodology.md), the
canonical home of the model). Cluster lifecycle is expressed as **step kinds** in that chain.
`hostbootstrap-core` contributes the cluster step kinds (`deploy-kind`-class steps plus the chart
deploy); a project contributes its own steps (`deploy-registry`, `push-image`, …) into the *same*
`[Step]`, and host and workload steps interleave freely. The cluster steps are leaves: they bottom out
at the container frame into `kubectl`/`helm`/`kind`.

`HostBootstrap.Cluster.Lifecycle` provides the cluster-step actions and applies the resource cordon
(`HostBootstrap.Cluster.Cordon`) from [resource_budgeting](resource_budgeting.md). The plan resolution
(`resolvePlan`), the teardown partition (`teardown`), and the status report (`statusReport`) are pure,
so the never-delete-`.data` invariant, the production-versus-test profile distinction, and the status
shape are unit-tested; the IO drivers run `kind`/`Helm` through the `HostTool` enumeration. Accelerator
plans also carry a pure cluster driver: normal paths use `KindDriver`; Linux GPU accelerator plans use
`NvkindDriver`, which creates a control-plane plus GPU worker with `nvkind cluster create
--name=<cluster>` after the official volume-mount NVIDIA-runtime smoke. The one cluster envelope is divided
across both node containers, then bring-up installs the pinned NVIDIA device-plugin chart and requires a
positive allocatable `nvidia.com/gpu`. Health checks, kubeconfig export, and teardown keep using the
resulting kind cluster name. The
semantics are shared so a project does not re-implement cluster orchestration; its chain selects a
profile and supplies the chart, and the core interprets the step.

The chart-deploy action takes a **generic project extra-values** parameter so a project can forward its own
config fields into the chart without core learning the field:

```haskell
deployChart :: HostConfig -> ClusterPlan -> [(Text, Text)] -> IO ()
```

The `[(Text, Text)]` is an opaque set of Helm values core forwards verbatim; core never interprets the
keys. The demo uses it for rollout identity and placement values. The service ConfigMap itself is rendered
from the exact parent-derived `ProjectConfig` by the project binary and applied with `kubectl apply -f -`
before Helm runs. Its exact mounted bytes are fingerprinted into the Deployment annotation, so a config
change rolls the pod without teaching core about `message` or `ServiceType`.

## `project up`: Fail-Closed, Idempotent Bring-Up

A cluster step under `project up` is **fail-closed** and **idempotent** (reconcile-to-running). Its
kind/helm actions use `requireStep`, which `die`s on a non-zero `kind create` or
`helm upgrade --install`, so a broken deploy is loud — never a swallowed message a lifting parent
process would read as success.

`clusterCreate` upholds this against a busy or stale host with two gates. Because `kind create` defaults to
`--wait 0s`, it ends with a **node/CNI readiness gate** (`waitNodesReady`: bounded-retry
`kubectl wait --for=condition=Ready node --all`, fail-closed) so the chain's first `kubectl apply` / Helm
install cannot race the API server or CNI. And because `kind get clusters` lists only names, a listed
cluster is **health-probed** (`clusterHealthy`: export kubeconfig, then `kubectl get nodes`) rather than
trusted: a listed-but-unhealthy cluster (stopped containers after the VM that hosts it was
`project down`-stopped and restarted) is `kind delete`-d and recreated, so the idempotent re-run reconciles
a stopped in-VM stack back to running. The pure classifier `clusterHealthyFromProbe` is unit-tested.

The deploy is **chart-conditional**: a project ships its chart at `./chart` (relative to the directory
the cluster step runs in — the project root, or `/workspace/<project>` inside the project container)
and the step installs it fail-closed; a project with no chart gets a clean kind + cordon bring-up with
the deploy skipped — "no deploy requested", not a swallowed failure. The worked demo ships
`demo/chart/` (the webservice as a NodePort Service the Playwright e2e reaches).

The kube tools (`kubectl`/`helm`/`kind`) are **container** tools baked into the base image, run at the
container frame the recursive interpreter reaches — not host tools (see
[composition_methodology](../architecture/composition_methodology.md) and
[development_plan_standards § L](../../DEVELOPMENT_PLAN/development_plan_standards.md)).

### Accelerator daemon ingress

The accelerator demo adds a daemon WebSocket ingress on the web service. The chart renders it as a
distinct Service from the public web NodePort. In-cluster daemon pods use the configured `ClusterIP` port
(default 8081); host-resident Apple Silicon and Windows GPU daemons use NodePort 30081.
`acceleratorIngressPlan` is the
pure renderer for that choice. Placement-specific kind configs publish 30081 only for host-daemon lanes,
bound to `127.0.0.1`, so the daemon can connect without publishing the ingress on the LAN. In-cluster
kind/nvkind configs omit the mapping; the existing web/registry/MinIO NodePorts keep their historical
bindings. Linux GPU uses a direct host `nvkind` cluster rather than an Incus VM; Linux CPU keeps the Incus
VM path.

## `project down`: Delete Kind, Preserve State

`project down` deletes the running kind cluster and its services while preserving durable state. Kind does
not provide a reliable stop/restart contract for the cluster frame, so `down` uses `kind delete cluster`
for compute and keeps the `.data` and derived paths in place. The next `project up` recreates the kind
cluster from the chain. **In-VM topology:** when the kind cluster lives *inside* a provider VM (the demo
topology), `project down` stops the VM before the host-side `kind delete` can reach it, so the in-VM cluster
is left stopped rather than deleted; the re-run health-checks-and-recreates it — `clusterCreate` finds the
listed cluster unhealthy (`clusterHealthy`/`clusterHealthyFromProbe`), `kind delete`s and recreates it, then
gates on `waitNodesReady` before the first apply — rather than trusting `kind get clusters`. This VM-nested
`down`->`up` recreate is the same health-recreate path described under `project up` above, and is
real-run-validated 2026-07-05 by the Windows/WSL2 `hostbootstrap-demo test run all` (6/6 passed). VM frames are different: they use provider stop-without-delete (`incus stop` /
`limactl stop` / `wsl --terminate <distro>` (per-distro WSL2 stop)) on ascent after the inner cluster teardown (see
[incus](incus.md), [lima](lima.md), [wsl2](wsl2.md)).

Stop steps use the best-effort `reportStep`, which logs a failed step without aborting the rest of the
descent, so a partial stack is tolerated and the operation stays idempotent.

## `project destroy`: Best-Effort Teardown

`project destroy` stops, then **deletes** the kind cluster and its compute. The interpreter recurses
in (frame still up), then deletes on ascent (the VM is stopped/destroyed last). Like `down`, teardown
uses the best-effort `reportStep` so a failed step is logged without aborting the rest of teardown,
tolerating a partially-up stack and staying idempotent.

`destroy` removes the cluster and its compute but **never** deletes the cluster's `.data` directory
(see below).

## The Never-Delete-`.data` Invariant

Neither `down` nor `destroy` deletes a cluster's data directory.

- Production state lives in `.data`.
- Deleting the kind cluster on `down`, or tearing it down with `destroy` and recreating it with a later
  `up`, preserves the data directory so persistent state survives the cluster's lifecycle.

- **WRONG**: a teardown step removes the data directory along with the cluster. This is wrong because
  it destroys persistent state that must outlive the cluster, conflating compute lifecycle with data
  lifecycle.
- **RIGHT**: teardown removes only the cluster; the data directory is left in place for the next
  bring-up.

## Production vs Test Profiles

A cluster runs under a `ClusterProfile` that selects its data directory and cluster name:

| Profile | Data directory | Cluster name |
|---------|----------------|--------------|
| Production | `.data` | a fixed, project-defined cluster name |
| Test | `.test_data` | a test-scoped cluster name (test-prefixed and case-scoped) |

The test profile isolates the test harness from production state: it never touches `.data`, writing
instead under `.test_data`, and it uses a test-scoped cluster name so test clusters are clearly
distinct from production clusters. This isolation lets the test harness stand up, exercise, and tear
down clusters per case without endangering production data; the never-delete-data invariant still
applies to `.test_data` within a case's lifecycle.

`test run all` **drives** the persistent `project up` rather than being a separate bring-up: for each
config variant the suite declares, the harness generates that variant's `<project>.dhall` (the Test
profile, under `.test_data`), runs `project up`, asserts the live stack, and tears it down with `project
destroy` before the next variant — the demo runs two variants (`"Hello, world!"`, `"Hello, Universe!"`).
Two fail-fast preconditions protect production — the harness refuses if a config already exists at the
executable sibling `siblingProjectConfigPath` (`.build/<project>.dhall`, not the project root) or if a
**production cluster is running** (never touch production state) — and it deletes only the `.test_data` and
generated config it created this run. The production kind cluster is cordoned to a **slice within the VM
wall** (the budget = VM wall, cluster = slice rule, [resource_budgeting](resource_budgeting.md)), never the
full budget. *(The harness recast is implemented and real-run-validated — phase-10/13/17.)* See
[testing](testing.md).

## Current Status

The cluster-lifecycle semantics described above are real-run-validated end-to-end on real hardware.

- **Behavior**: cluster bring-up and teardown are chain steps the recursive `project up`/`project
  down`/`project destroy` interpreter runs, with `down` deleting the kind cluster while preserving durable
  state and `destroy` deleting it too. The `deploy-kind`/`deploy-chart` steps are fail-closed and chart-conditional;
  teardown attempts every independent cleanup and aggregates failures. Read-only state is reported through `context inspect`,
  which renders the lift composition with the current frame marked, reports whether the resolved cluster
  is live alongside the preserved `.data` and derived paths, and never mutates state. The
  `clusterCreate`/`deployChart`/`clusterUp`/`clusterDown`/`clusterDelete` reconcilers live in
  `HostBootstrap.Cluster.Lifecycle` and the chain-step actions invoke them. The never-delete-`.data`
  invariant and the production/test profiles are unit-tested and in force. The demo reaches this path
  through its substrate-selected `demoChainFor :: Substrate -> ProjectConfig -> [Step]` value
  (`demo/src/HostBootstrapDemo/Commands.hs`), interpreted by the same `project` lifecycle. Under the
  implemented generic project model, the demo renders and applies its exact service config before
  `deployChart`; Helm values carry only rollout/placement metadata (see [schema](schema.md) and
  [phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)). The accelerator lifecycle's
  static slice now includes the direct Linux GPU `nvkind` cluster driver, official NVIDIA runtime probe,
  control-plane/GPU-worker budget split, pinned device-plugin install/readiness/allocatable gate, CUDA
  daemon GPU limit, and placement-specific ingress/config selection. The current `-Werror` gates pass
  with 359 core tests and 87 demo tests; live Linux CPU/GPU daemon connectivity remains gated by the
  accelerator phases in the development plan.
- **Validated end-state**: a single `project up` on Incus/Linux stands up the live persistent stack —
  the cordoned kind cluster (kind `extraPortMappings` publish NodePorts to the VM localhost), the
  in-cluster registry (NodePort 30500), the project image pushed to that registry, and the web
  chart pod serving HTTP 200 at `localhost:30080` — and `project down` / `project destroy` tear it down
  with host `.data` preserved.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — the canonical home of the
  chain-is-the-project model and the recursive `project up` interpreter.
- [resource_budgeting](resource_budgeting.md) — the cordon the cluster steps apply.
- [dhall_topology](dhall_topology.md) — the topology frames that drive the recursive chain.
- [incus](incus.md), [lima](lima.md) — VM lifecycle expressed as core chain steps, including
  stop-without-delete.
- [testing](testing.md) — `test run all`, the harness that drives the real `project up` under a test config
  (Test profile, `.test_data`) and asserts the live stack.
