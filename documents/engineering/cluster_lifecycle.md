# Cluster Lifecycle

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [resource_budgeting](resource_budgeting.md), [dhall_topology](dhall_topology.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [testing](testing.md)

> **Purpose**: Define the kind/Helm cluster-lifecycle semantics `hostbootstrap-core` provides to
> consumers and the test harness, including the never-delete-`.data` invariant and the
> production-versus-test profile concept.

## TL;DR

- `hostbootstrap-core` owns the kind/Helm cluster-lifecycle semantics consumers and the test harness
  share.
- The lifecycle never deletes a cluster's `.data` directory: persistent state survives bring-up and
  teardown.
- A cluster runs under one of two profiles. The production profile uses `.data` and a fixed cluster
  name; the test profile uses `.test_data` and a test-scoped cluster name.

## What the Lifecycle Provides

`HostBootstrap.Cluster.Lifecycle` provides the verbs consumers and the test harness drive (`cluster
up` / `cluster down` / `cluster delete`, plus the read-only `cluster status`), and applies the
resource cordon (`HostBootstrap.Cluster.Cordon`) from [resource_budgeting](resource_budgeting.md). The
plan resolution (`resolvePlan`), the teardown partition (`teardown`), and the status report
(`statusReport`) are pure, so the never-delete-`.data` invariant, the production-versus-test profile
distinction, and the status shape are unit-tested; the IO drivers run `kind`/`Helm` through the
`HostTool` enumeration. `cluster status` probes `kind get clusters` and reports whether the resolved
cluster is live alongside the preserved `.data` and derived paths, never mutating state. The semantics
are shared so a project does not re-implement cluster orchestration; it selects a profile and supplies
its bootstrap instructions.

## Fail-closed `up`, best-effort teardown

`cluster up` is **fail-closed** on its kind/helm steps: `requireStep` `die`s on a non-zero `kind create`
or `helm upgrade --install`, so a broken deploy is loud — never a swallowed message a lifting parent
process would read as success. The deploy is **chart-conditional**: a project ships its chart at `./chart`
(relative to the directory `cluster up` runs in — the project root, or `/workspace/<project>` inside the
project container) and `cluster up` installs it fail-closed; a project with no chart gets a clean
kind + cordon bring-up with the deploy skipped — "no deploy requested", not a swallowed failure. The
worked demo ships `demo/chart/` (the webservice as a NodePort Service the Playwright e2e reaches).
Teardown (`down`/`delete`) uses the
best-effort `reportStep`, which logs a failed step without aborting the rest of teardown. The kube tools
(`kubectl`/`helm`/`kind`) are **container** tools baked into the base image, run in the in-container path
reached by the self-reference lift — not host tools (see
[composition_methodology](../architecture/composition_methodology.md) and
[development_plan_standards § L](../../DEVELOPMENT_PLAN/development_plan_standards.md)).

## The Never-Delete-`.data` Invariant

Cluster teardown removes the kind cluster and its compute, but it never deletes the cluster's data
directory.

- Production state lives in `.data`.
- Tearing a cluster down (or recreating it) preserves the data directory so persistent state
  survives the cluster's lifecycle.

- **WRONG**: cluster teardown removes the data directory along with the cluster. This is wrong
  because it destroys persistent state that must outlive the cluster, conflating compute lifecycle
  with data lifecycle.
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
distinct from production clusters. This isolation is what lets the host-driven test harness stand up,
exercise, and tear down clusters per case without endangering production data; the never-delete-data
invariant still applies to `.test_data` within a case's lifecycle. See [testing](testing.md) for how
the harness drives these profiles.
