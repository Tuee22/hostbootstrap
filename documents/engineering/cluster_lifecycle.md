# Cluster Lifecycle

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [resource_budgeting](resource_budgeting.md), [dhall_topology](dhall_topology.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [testing](testing.md)

> **Purpose**: Define the kind/Helm cluster-lifecycle semantics `hostbootstrap-core` provides as
> chain steps under `project up`/`project down`/`project destroy`, including the
> stop-without-delete capability, the never-delete-`.data` invariant, and the
> production-versus-test profile concept.

## TL;DR

- Cluster bring-up and teardown are **chain steps**. The core ships `deploy-kind`-class step kinds
  that the recursive `project up`/`project down`/`project destroy` interpreter runs at the container
  frame, where the chain bottoms out into `kubectl`/`helm`/`kind` leaves.
- `project up` brings the cluster to *running* (idempotent, fail-closed). `project down` **stops**
  the cluster without deleting it. `project destroy` stops, then deletes the cluster and its compute.
- The lifecycle never deletes a cluster's `.data` directory: persistent state survives bring-up,
  stop, and teardown.
- A cluster runs under one of two profiles. The production profile uses `.data` and a fixed cluster
  name; the test profile uses `.test_data` and a test-scoped cluster name.
- The chain `[Step]` value is the project; cluster steps interleave with host-management steps in
  the same chain. The model itself is owned by
  [composition_methodology](../architecture/composition_methodology.md); this doc defers to it and
  describes the cluster-specific steps.

## Cluster Steps In The Chain

The chain is the project: `chain :: ProjectConfig -> [Step]` is one ordered representation the recursive
interpreter walks (see [composition_methodology](../architecture/composition_methodology.md), the
canonical home of the model). Cluster lifecycle is expressed as **step kinds** in that chain.
`hostbootstrap-core` contributes the cluster step kinds (`deploy-kind`-class steps plus the chart
deploy); a project contributes its own steps (`deploy-harbor`, `push-image`, …) into the *same*
`[Step]`, and host and workload steps interleave freely. The cluster steps are leaves: they bottom out
at the container frame into `kubectl`/`helm`/`kind`.

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

`project down` **stops** the running cluster and its services without deleting anything. The cluster's
compute is paused so the host reclaims resources, while the cluster definition, its `.data`, and its
derived paths are left in place so the next `project up` resumes the same cluster rather than recreating
it. `down` recurses *in* (the frame is still up) and stops on ascent, mirroring how VM `down` stops the
VM without destroying it (see [incus](incus.md), [lima](lima.md)).

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
- Stopping a cluster (`down`), or tearing it down with `destroy` and recreating it with a later
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

`test run all` **drives** the persistent `project up` rather than being a separate bring-up: per distinct
test config the harness runs `project up` under a test-written `<project>.dhall` (the Test profile, under
`.test_data`), asserts the live stack, and tears it down with `project destroy`. Two fail-fast
preconditions protect production — the harness refuses if a `<project>.dhall` already exists or if a
**production cluster is running** (never touch production state) — and it deletes only the `.test_data` and
config it created this run. The production kind cluster is cordoned to a **slice within the VM wall** (the
budget = VM wall, cluster = slice rule, [resource_budgeting](resource_budgeting.md)), never the full
budget. *(Target; the harness recast is reopened, real-run-gated — phase-10/13/17.)* See
[testing](testing.md).

## Current Status

The cluster-lifecycle semantics described above are real-run-validated end-to-end on real hardware.

- **Behavior**: cluster bring-up and teardown are chain steps the recursive `project up`/`project
  down`/`project destroy` interpreter runs, with `down` stopping the cluster without deleting it and
  `destroy` deleting it. The `deploy-kind`/`deploy-chart` steps are fail-closed and chart-conditional;
  the stop and teardown steps are best-effort. Read-only state is reported through `context inspect`,
  which renders the lift composition with the current frame marked, reports whether the resolved cluster
  is live alongside the preserved `.data` and derived paths, and never mutates state. The
  `clusterCreate`/`deployChart`/`clusterUp`/`clusterDown`/`clusterDelete` reconcilers live in
  `HostBootstrap.Cluster.Lifecycle` and the chain-step actions invoke them. The never-delete-`.data`
  invariant and the production/test profiles are unit-tested and in force. The demo reaches this path
  through its `demoChain :: ProjectConfig -> [Step]` value
  (`demo/src/HostBootstrapDemo/Commands.hs`), interpreted by the same `project` lifecycle.
- **Validated end-state**: a single `project up` on Incus/Linux stands up the live persistent stack —
  the cordoned kind cluster (kind `extraPortMappings` publish NodePorts to the VM localhost), the
  in-cluster Harbor registry (NodePort 30500), the project image pushed to that registry, and the web
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
