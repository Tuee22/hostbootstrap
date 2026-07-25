# Durable State

**Status**: Authoritative source
**Supersedes**: the claim that no production code creates `.data` or that durable carry is only planned
**Referenced by**: [readiness](readiness.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [WSL2](../engineering/wsl2.md), [Lima](../engineering/lima.md), [Incus](../engineering/incus.md), [documents index](../README.md)

> **Purpose**: Define canonical host-root authority and its typed durable-path projections, explain the
> current compatibility alias, and state what remains before destroy/up/readback is proved.

## TL;DR

The target resolves descriptive `sourceRoot` once into opaque canonical project-root authority.
Production `.data` and every host, guest, container, kind-node, and pod path are typed projections of
that identity. Provider lanes may use `/var/tmp/hostbootstrap-demo-data` as a guest-local projection;
direct-host Docker must bind the actual canonical host `.data` directory. The current implementation
still substitutes the compatibility alias on direct Linux, so end-to-end durability remains unvalidated.

## Current Status

The current demo does create and carry durable state:

```text
host project root/.data
        │ provider share (drvfs, Incus disk device, or Lima mount)
        ▼
Linux environment's substrate-specific mounted path
        │ provider-local guest symlink
        ▼
/var/tmp/hostbootstrap-demo-data
        │ Docker/kind extraMount
        ▼
/var/lib/hostbootstrap-demo-data
        │ pod hostPath
        ▼
/var/lib/hostbootstrap-demo-data/web
```

`/var/tmp/hostbootstrap-demo-data` is not the canonical store or a portable host path. It is a
provider-guest projection used where the Docker daemon runs inside WSL2, Incus, or Lima. On direct
Linux, Docker must receive the canonical absolute host `.data` path; kind/nvkind then projects that
source into the node path. The web pod mounts the final `/web` directory from the kind node.

The canonical host directory is `<project-root>/.data`. Provider setup creates it, carries it into the
VM/container topology, waits for the share, and reconciles the guest alias. The direct Linux GPU lane
currently uses that alias too; Sprint 5.6.1 reopens this as a compatibility defect.

## What is implemented

- `HostPathShare`/`ShareReconcile` describe the provider-specific host-to-guest carry.
- WSL2 uses the host drive exposed by drvfs, Incus attaches a disk device, and Lima declares a mount.
- Provider and direct-host paths create the host durable root; current code also attempts to establish
  `/var/tmp/hostbootstrap-demo-data` in both cases.
- Project-container, kind/nvkind, and pod configurations carry the directory to the web workload.
- Cluster teardown excludes its configured data path from its filesystem removal set.

These facts supersede the older description that `.data` was only frame-relative guest state and that no
code created it.

## Open defects

The carry is not yet a delivered durability guarantee:

- Direct Linux passes `/var/tmp/hostbootstrap-demo-data` to Docker because the pure frame context has
  only relative `sourceRoot = "."`; Docker rejects that symlink as a bind source. The target deletes
  this direct-host alias path and supplies the canonical absolute host `.data` projection.
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

## Root authority and alias target

Root-config admission resolves relative `sourceRoot` against the stable project-home anchor owned by the
selected root config—not `cwd` or the executable's sibling `.build` directory—then verifies and
canonicalizes it once. Its rank-2 `CanonicalProjectRoot scope rootId` is the only source of host durable
paths. `ProjectPlan` derives the lifecycle-profile root and all boundary projections under the same
identity. Raw `FilePath` values and guest aliases cannot enter a host-bind adapter.

Alias reconciliation remains necessary only for provider guests. It is a typed projection operation,
not root discovery or authority.

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

1. Each provider-guest clean-path test reaches `AliasAbsent`, creates the link, and reruns to
   `ManagedResult Unchanged` with the same verified receipt.
2. Wrong-link, occupied-node, permission, and unexpected IO failures are reported without partial
   filesystem exceptions.
3. Root-resolution tests are independent of process `cwd`; wrong/replaced roots fail before plan
   construction, and API tests prevent guest/container paths from entering direct-host bind operations.
4. Direct Linux reaches Docker with the canonical absolute nonsymlink host `.data` path; each provider
   lane reaches it through only its own typed guest projection.
5. Every supported native substrate writes a unique value through the pod-mounted `/web` path, destroys
   the stack, recreates it, and reads the value from both host and pod.
6. `test run all` proves its cluster name is test-scoped and that neither `.data` nor the production
   cluster is observed or mutated.
7. Recursive teardown visits the child cluster/container before stopping or deleting its provider frame.

Validation status and scheduling belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [lifecycle state model](lifecycle_state_model.md) — typed transitions, opaque readiness and ownership,
  total probes, and recursive teardown.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/Helm operations.
- [harness workflow](harness_workflow.md) — current test-profile and DSL mismatch.
- [gitignore guardrails](../engineering/gitignore_guardrails.md) — keeping `.data/` and `.test_data/`
  outside version control.
