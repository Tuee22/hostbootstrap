# Durable State

**Status**: Authoritative source
**Supersedes**: the claim that no production code creates `.data` or that durable carry is only planned
**Referenced by**: [readiness](readiness.md), [cluster lifecycle](../engineering/cluster_lifecycle.md), [WSL2](../engineering/wsl2.md), [Lima](../engineering/lima.md), [Incus](../engineering/incus.md), [documents index](../README.md)

> **Purpose**: Define canonical host-root authority and its typed durable-path projections, explain the
> current compatibility alias, and record how far destroy/up/readback is proved.

## TL;DR

Root-config admission now resolves descriptive `sourceRoot` once into opaque
`CanonicalProjectRoot scope rootId` authority without rewriting the descriptive context. Direct-host
Docker binds the matching typed canonical `.data` projection; provider lanes continue to use
`/var/tmp/hostbootstrap-demo-data` only as a guest-local projection. The final opaque plan still has to
carry all guest, container, kind-node, and pod projections. End-to-end durability is **proved on the
native Linux GPU direct lane** by the `durable-readback` harness case; every other provider lane remains
unvalidated.

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
instead receives the canonical absolute host directory from root admission; it does not substitute the
guest alias.

## What is implemented

- `HostPathShare`/`ShareReconcile` describe the provider-specific host-to-guest carry.
- WSL2 uses the host drive exposed by drvfs, Incus attaches a disk device, and Lima declares a mount.
- Provider and direct-host paths create the host durable root. Provider guests establish
  `/var/tmp/hostbootstrap-demo-data`; the direct-host Docker handoff consumes the typed canonical path.
- Root lifecycle frame/teardown callbacks receive `CanonicalProjectRoot scope rootId` separately from
  `BinaryContext`, and the host-mount adapter accepts only a `CanonicalHostPath` carrying the same
  indices.
- Project-container, kind/nvkind, and pod configurations carry the directory to the web workload.
- Cluster teardown excludes its configured data path from its filesystem removal set.

These facts supersede the older description that `.data` was only frame-relative guest state and that no
code created it.

## Open defects

The carry is not yet a delivered durability guarantee:

- The current `ProjectSpec` still keeps teardown as a representation separate from the plan (the
  forward chain and each frame's descent are now one plan value).
  The final `ProjectPlan` must retain the canonical authority and derive every
  provider-guest/container/kind-node/pod projection rather than letting remaining adapters accept raw
  path values.
- VM-shell and direct observations do not yet share one total, typed probe result at the IO boundary.
- `/var/tmp/hostbootstrap-demo-data` is created and removed by pathname. Current logic holds none of the
  four [ownership invariant](ownership_invariant.md) clauses — no exclusive entry, no durable origin
  record, no identity binding, no conditional release — so it cannot mint a cleanup receipt. This is
  true on every provider guest, not only one: Lima and Incus aliases are in exactly the same state as
  WSL2's.
- `DurableStore` is not uniform mutation authority. Core `service run` now binds typed role selection and
  handler fields to one canonically verified sibling snapshot, but neither Web nor accelerator handler
  yet receives plan-derived effect/capability authority. The remaining raw handler `IO` therefore does
  not prove durable placement.
- The demo test harness currently resolves `containerPlan` with the `Production` profile. It creates and
  mounts `.data`; the nominal `.test_data` lifecycle is not what the live demo cluster uses.
- The `durable-readback` case does write through the pod path, run `project destroy`, run `project up`,
  and read the same bytes back — but only the native Linux GPU direct lane has run it. Lima, Incus, and
  WSL2 have no such result.
- Teardown is not a recursive child-to-parent interpretation. A provider VM can be stopped or removed by
  the plan's reverse projection without first running the lifecycle verb in each child frame.

Documentation must therefore describe the mechanism as **durable carry implemented, end-to-end
persistence proved on the direct Linux lane only**. A statement covering another provider needs that
provider's own run.

## Root authority and alias target

Root-config admission resolves relative `sourceRoot` against the stable project-home anchor owned by the
selected root config—not caller `cwd` or the executable's sibling `.build` directory—then verifies and
canonicalizes it once. Its rank-2 `CanonicalProjectRoot scope rootId` is the only source of direct-host
durable paths. `CanonicalHostPath` construction is private, and the host-bind adapter requires the root
and path to carry the same `scope`/`rootId`; raw `FilePath`, redirected roots, and cross-root projections
are rejected.

The final `ProjectPlan` target derives the lifecycle-profile root and all remaining boundary projections
under that identity. That broader plan work is not yet implemented.

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
Alias reconciliation may mint a receipt only when the backend holds all four
[ownership invariant](ownership_invariant.md) clauses. Because all three provider guests run the same
Linux image, one backend satisfies them identically on WSL2, Lima, and Incus: `flock` for exclusive
entry, a host-side origin record, `stat -c '%d %i'` for identity binding, and a compare-before-`unlink`
release. A host that cannot supply a clause returns `Unsupported` and mints no receipt. Sprints 9.10 and
11.10 own the shared algebra and the provider-guest integration.

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
   `ManagedResult Unchanged` with the same verified receipt. This runs on **every** provider guest —
   WSL2, Lima, and Incus — because one backend serves all three.
2. Wrong-link, occupied-node, permission, and unexpected IO failures are reported without partial
   filesystem exceptions. A run killed between the durable origin record and the link creation is
   recoverable, including the case where the alias path was originally **absent**: the next run
   restores absence rather than adopting what the killed run left behind. An alias replaced by a
   same-privilege process between observation and mutation is reported as `Conflict` with
   expected/observed identity, is not clobbered, and mints no receipt; release is refused on identity
   mismatch. See [ownership_invariant](ownership_invariant.md) § Validation for the full clause suite.
3. **Passed 2026-07-25:** root-resolution tests are independent of process `cwd`; missing, wrong-kind,
   escaping, and redirected roots fail before the callback, and compile-fail tests prevent raw or
   cross-root paths from entering direct-host bind operations.
4. **Direct half passed:** native Linux reached Docker with the canonical absolute nonsymlink host
   `.data` path. Final plan-indexed provider guest projections remain open.
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
- [ownership invariant](ownership_invariant.md) — the four clauses the alias backend must hold before it
  may mint a cleanup receipt.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/Helm operations.
- [harness workflow](harness_workflow.md) — current test-profile and DSL mismatch.
- [gitignore guardrails](../engineering/gitignore_guardrails.md) — keeping `.data/` and `.test_data/`
  outside version control.
