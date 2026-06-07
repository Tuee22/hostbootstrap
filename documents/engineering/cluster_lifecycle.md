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
up` / `cluster down` / `cluster delete`), and applies the resource cordon
(`HostBootstrap.Cluster.Cordon`) from [resource_budgeting](resource_budgeting.md). The plan
resolution (`resolvePlan`) and the teardown partition (`teardown`) are pure, so the
never-delete-`.data` invariant and the production-versus-test profile distinction are unit-tested; the
IO drivers run `kind`/`Helm` through the `HostTool` enumeration. The semantics are shared so a project
does not re-implement cluster orchestration; it selects a profile and supplies its bootstrap
instructions.

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
