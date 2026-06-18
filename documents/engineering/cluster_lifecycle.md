# Cluster Lifecycle

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [resource_budgeting](resource_budgeting.md), [dhall_topology](dhall_topology.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [testing](testing.md)

> **Purpose**: Define the kind/Helm cluster-lifecycle semantics `hostbootstrap-core` provides as
> chain steps under `project up`/`project down`/`project destroy`, including the
> stop-without-delete capability, the never-delete-`.data` invariant, and the
> production-versus-test profile concept.

## TL;DR

- Cluster bring-up and teardown are **chain steps**, not standalone verbs. The core ships
  `deploy-kind`-class step kinds that the recursive `project up`/`project down`/`project destroy`
  interpreter runs at the container frame, where the chain bottoms out into `kubectl`/`helm`/`kind`
  leaves.
- `project up` brings the cluster to *running* (idempotent, fail-closed). `project down` **stops**
  the cluster without deleting it (new capability). `project destroy` stops, then deletes the
  cluster and its compute.
- The lifecycle never deletes a cluster's `.data` directory: persistent state survives bring-up,
  stop, and teardown.
- A cluster runs under one of two profiles. The production profile uses `.data` and a fixed cluster
  name; the test profile uses `.test_data` and a test-scoped cluster name.
- The chain `[Step]` value is the project; cluster steps interleave with host-management steps in
  the same chain. The model itself is owned by
  [composition_methodology](../architecture/composition_methodology.md); this doc defers to it and
  describes the cluster-specific steps.

## Cluster Steps In The Chain

The chain is the project: `chain :: RootConfig -> [Step]` is one ordered representation the recursive
interpreter walks (see [composition_methodology](../architecture/composition_methodology.md), the
canonical home of the model). Cluster lifecycle is expressed as **step kinds** in that chain, not as a
top-level `cluster` command. `hostbootstrap-core` contributes the cluster step kinds
(`deploy-kind`-class steps plus the chart deploy); a project contributes its own steps
(`deploy-harbor`, `launch-web`, …) into the *same* `[Step]`, and host and workload steps interleave
freely. The cluster steps are leaves: they bottom out at the container frame into `kubectl`/`helm`/`kind`.

`HostBootstrap.Cluster.Lifecycle` provides the cluster-step actions and applies the resource cordon
(`HostBootstrap.Cluster.Cordon`) from [resource_budgeting](resource_budgeting.md). The plan resolution
(`resolvePlan`), the teardown partition (`teardown`), and the status report (`statusReport`) are pure,
so the never-delete-`.data` invariant, the production-versus-test profile distinction, and the status
shape are unit-tested; the IO drivers run `kind`/`Helm` through the `HostTool` enumeration. The
semantics are shared so a project does not re-implement cluster orchestration; its chain selects a
profile and supplies the chart, and the core interprets the step.

## `project up`: Fail-Closed, Idempotent Bring-Up

A cluster step under `project up` is **fail-closed** and **idempotent** (reconcile-to-running). Its
kind/helm actions use `requireStep`, which `die`s on a non-zero `kind create` or
`helm upgrade --install`, so a broken deploy is loud — never a swallowed message a lifting parent
process would read as success.

The deploy is **chart-conditional**: a project ships its chart at `./chart` (relative to the directory
the cluster step runs in — the project root, or `/workspace/<project>` inside the project container)
and the step installs it fail-closed; a project with no chart gets a clean kind + cordon bring-up with
the deploy skipped — "no deploy requested", not a swallowed failure. The worked demo ships
`demo/chart/` (the webservice as a NodePort Service the Playwright e2e reaches).

The kube tools (`kubectl`/`helm`/`kind`) are **container** tools baked into the base image, run at the
container frame the recursive interpreter reaches — not host tools (see
[composition_methodology](../architecture/composition_methodology.md) and
[development_plan_standards § L](../../DEVELOPMENT_PLAN/development_plan_standards.md)).

## `project down`: Stop Without Delete

`project down` **stops** the running cluster and its services without deleting anything. This is a new
capability distinct from teardown: the cluster's compute is paused so the host reclaims resources, but
the cluster definition, its `.data`, and its derived paths are left in place so the next `project up`
resumes the same cluster rather than recreating it. `down` recurses *in* (the frame is still up) and
stops on ascent, mirroring how VM `down` stops the VM without destroying it (see
[incus](incus.md), [lima](lima.md)).

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

Neither stop (`down`) nor teardown (`destroy`) deletes a cluster's data directory.

- Production state lives in `.data`.
- Stopping a cluster (`down`), or tearing it down and recreating it (`destroy` → `up`), preserves the
  data directory so persistent state survives the cluster's lifecycle.

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
distinct from production clusters. This isolation is what lets the test harness stand up, exercise,
and tear down clusters per case without endangering production data; the never-delete-data invariant
still applies to `.test_data` within a case's lifecycle. The harness drives these profiles as a **lift
target**, decoupled from the production chain: `test run all` validates the live `project up` stack
from the root frame. See [testing](testing.md).

## Current Status

The cluster-lifecycle semantics described above ship today and are real-run-validated end-to-end on
real hardware.

- **Shipped**: cluster bring-up/teardown are chain steps the recursive `project up`/`project
  down`/`project destroy` interpreter runs, with stop-without-delete (`down`) as a capability distinct
  from `destroy`. The `deploy-kind`/`deploy-chart` steps are fail-closed and chart-conditional; the
  stop and teardown steps are best-effort; read-only state is reported through `context inspect`, which
  renders the lift composition and current frame and reports whether the resolved cluster is live
  alongside the preserved `.data` and derived paths, never mutating state. The flat `cluster
  up|down|delete|status` verbs are removed; the `clusterUp`/`clusterCreate`/`deployChart`/`clusterDown`/
  `clusterDelete` reconcilers remain in `HostBootstrap.Cluster.Lifecycle`, invoked by the chain steps
  and the lifecycle command. The never-delete-`.data` invariant and the production/test profiles are
  unit-tested and in force. The demo reaches this path through its `demoChain :: ProjectConfig ->
  [Step]` value (`demo/src/HostBootstrapDemo/Commands.hs`), interpreted by the same `project` lifecycle.
- **Validated end-state**: a single `project up` on Incus/Linux stood up the live persistent stack —
  the cordoned kind cluster (kind `extraPortMappings` publish NodePorts to the VM localhost), the full
  8-pod production Harbor (NodePort 30500), the 20GB project image pushed to the in-cluster registry,
  and the web chart pod serving HTTP 200 at `localhost:30080` — then `project down` / `project destroy`
  tore it down with host `.data` preserved.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — the canonical home of the
  chain-is-the-project model and the recursive `project up` interpreter.
- [resource_budgeting](resource_budgeting.md) — the cordon the cluster steps apply.
- [dhall_topology](dhall_topology.md) — the topology frames that drive the recursive chain.
- [incus](incus.md), [lima](lima.md) — VM lifecycle expressed as core chain steps, including
  stop-without-delete.
- [testing](testing.md) — how the harness drives the production/test profiles as a decoupled lift
  target.
