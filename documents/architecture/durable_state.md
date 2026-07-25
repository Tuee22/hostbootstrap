# Durable State

**Status**: Authoritative source
**Supersedes**: the claim that no production code creates `.data` or that durable carry is only planned
**Referenced by**: [readiness](readiness.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [WSL2](../engineering/wsl2.md), [Lima](../engineering/lima.md), [Incus](../engineering/incus.md), [documents index](../README.md)

> **Purpose**: Explain the demo's host durable root, the stable Docker-visible
> `/var/tmp/hostbootstrap-demo-data` alias, what is implemented, and what still lacks a destroy/up/readback
> proof.

## TL;DR

The demo currently carries host `<project-root>/.data` through its provider, a stable
`/var/tmp/hostbootstrap-demo-data` Docker-visible alias, kind/nvkind, and the workload. That mechanism is
implemented, but a partial direct-host probe, Production-profile demo tests, nonrecursive teardown, and
the missing live destroy/up/readback gate mean end-to-end durability is not yet validated.

## Current Status

The current demo does create and carry durable state:

```text
host project root/.data
        │ provider share (drvfs, Incus disk device, or Lima mount)
        ▼
Linux environment's substrate-specific mounted path
        │ symlink
        ▼
/var/tmp/hostbootstrap-demo-data
        │ Docker/kind extraMount
        ▼
/var/lib/hostbootstrap-demo-data
        │ pod hostPath
        ▼
/var/lib/hostbootstrap-demo-data/web
```

`/var/tmp/hostbootstrap-demo-data` is not the canonical store. It is the stable Linux path presented to
the Docker daemon regardless of whether the underlying host directory arrived through WSL drvfs, an
Incus disk device, a Lima mount, or the direct Linux host. Kind and nvkind configuration can therefore
use one `hostPath` on every lane. The web pod mounts the final `/web` directory from the kind node.

The canonical host directory is `<project-root>/.data`. Provider setup creates it, carries it into the
VM/container topology, waits for the share, and reconciles the stable alias. The direct Linux GPU lane
uses the same alias name on the host that runs Docker.

## What is implemented

- `HostPathShare`/`ShareReconcile` describe the provider-specific host-to-guest carry.
- WSL2 uses the host drive exposed by drvfs, Incus attaches a disk device, and Lima declares a mount.
- Provider and direct-host paths create the host durable root and attempt to establish
  `/var/tmp/hostbootstrap-demo-data`.
- Project-container, kind/nvkind, and pod configurations carry the directory to the web workload.
- Cluster teardown excludes its configured data path from its filesystem removal set.

These facts supersede the older description that `.data` was only frame-relative guest state and that no
code created it.

## Open defects

The carry is not yet a delivered durability guarantee:

- The direct-host alias observation is partial: it calls `pathIsSymbolicLink` before proving the alias
  exists. A clean first run throws instead of classifying `AliasAbsent`, so direct Linux GPU bring-up can
  fail before creating the link.
- VM-shell and direct observations do not yet share one total, typed probe result at the IO boundary.
- `/var/tmp/hostbootstrap-demo-data` is an ordinary shared pathname. Current create/check/remove logic
  cannot exclude a same-privilege process replacing it between operations, so it is not an
  identity-authoritative ownership backend and cannot honestly mint a strong cleanup receipt.
- `DurableStore` is not uniform mutation authority. Initial core `service run` dispatch and the
  accelerator handler require no capability; only the Web handler's later sibling-config reload asks
  `validateContext` for `[DurableStore]`. That check consumes an editable decoded label after selection,
  so it neither binds one config snapshot nor proves durable placement.
- The demo test harness currently resolves `containerPlan` with the `Production` profile. It creates and
  mounts `.data`; the nominal `.test_data` lifecycle is not what the live demo cluster uses.
- No live gate writes through the pod path, runs `project destroy`, runs `project up`, and reads the same
  bytes back from both host and pod.
- Teardown is not a recursive child-to-parent interpretation. A provider VM can be stopped or removed by
  the project hook without first running the lifecycle verb in each child frame.

Until the destroy/up/readback gate passes, documentation must describe the mechanism as **durable carry
implemented, end-to-end persistence unvalidated**.

## Alias state target

The target classifier is total:

```haskell
data AliasState
  = AliasAbsent
  | AliasLinkedCorrectly
  | AliasLinkedElsewhere FilePath
  | AliasOccupied NodeKind
```

The plan's dependency-snapshot transition internally traverses the alias descriptor's exact
`PlannedEdge scope planId aliasId DurableAlias shareId DurableShare DurableShareMounted`, looks up the
managed mounted-share handle, and runs the plan-owned probe. The caller cannot supply or omit the edge or
substitute a retained `Ready`. The plan seals that fresh observation into the alias operation's closed
`OperationPreconditionSet`; prepare reruns the probe and identity/version checks and jointly returns the
only `PreparedOperation`/`PreparedPreconditions` pair the alias backend adapter accepts.
It returns `ReconcileResult scope planId aliasId DurableAlias Observed to`. The public entry accepts only an
unclassified handle in the `Observed` phase. It creates only `AliasAbsent`, returns
`ManagedResult Unchanged` only for a correctly linked alias with a verified receipt, and reports the
observed target/node on conflicts. A correctly linked foreign alias returns `ForeignResult` with an
`Unmanaged` handle, not mutation/deletion authority. Destructive cleanup requires the managed handle and
matching opaque ownership receipt; it never removes an alias merely because its pathname matches. IO
failure is `ProbeFailed`/`Failure` in the probe/reconcile error sum, not an alias state.
Strong alias reconciliation is available only when the substrate supplies a protected namespace plus an
identity-bound conditional mutation/delete (or an equivalent kernel/provider primitive). Otherwise it
returns `Unsupported`; an explicitly named cooperative pathname guard may aid diagnostics but cannot
mint the strong receipt. Sprints 9.10 and 11.10 own the shared algebra and Incus/filesystem integration.

The broader capability and ownership contract is defined in
[lifecycle_state_model](lifecycle_state_model.md).

The service-runtime target derives durable-store use from the selected closed program's effect row and
packages it only with a matching `ServiceSelection` proof and opaque durable-placement authority. A
late handler-specific config reload cannot mint or widen that authority.

## Production and test profiles

The current library enum can describe:

| Profile | Durable root | Cluster identity |
|---|---|---|
| Production | `.data` | fixed project production name |
| `TestCase caseId` | `.test_data/<caseId>` | `<project>-test-<caseId>` |

The cluster library can represent both, and generic harness ownership helpers manage `.test_data`.
However, the demo's live bring-up currently hardcodes `Production`, so tests exercise the first row.
This is an open safety defect. A passing unit test over a fabricated Test plan does not prove the demo
uses it.

The target is the opaque, scope-indexed `LifecycleProfile` in
[lifecycle_state_model](lifecycle_state_model.md): the production gate can mint only Production
authority, and the harness can mint only `Harness projectId runId`. `withProjectPlan` consumes that profile and
scope-matching config; `containerPlan` is only a projection of the resulting plan and derives the data
root and cluster identity together. A test config then cannot silently request Production.

## Teardown guarantee

The narrow, current guarantee is that cluster teardown does not include the plan's data path in its
filesystem removal set. That guarantee does not by itself prove:

- that the path is the host path;
- that every enclosing frame preserves the share;
- that a destroy/up cycle reattaches it correctly; or
- that the test harness avoids production state.

Those claims require the live validation gates below.

## Validation gates

1. A clean-host alias test reaches `AliasAbsent`, creates the link, and reruns to
   `ManagedResult Unchanged` with the same verified receipt.
2. Wrong-link, occupied-node, permission, and unexpected IO failures are reported without partial
   filesystem exceptions.
3. Every supported native substrate writes a unique value through the pod-mounted `/web` path, destroys
   the stack, recreates it, and reads the value from both host and pod.
4. `test run all` proves its cluster name is test-scoped and that neither `.data` nor the production
   cluster is observed or mutated.
5. Recursive teardown visits the child cluster/container before stopping or deleting its provider frame.

Validation status and scheduling belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [lifecycle state model](lifecycle_state_model.md) — typed transitions, opaque readiness and ownership,
  total probes, and recursive teardown.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/Helm operations.
- [harness workflow](harness_workflow.md) — current test-profile and DSL mismatch.
- [gitignore guardrails](../engineering/gitignore_guardrails.md) — keeping `.data/` and `.test_data/`
  outside version control.
