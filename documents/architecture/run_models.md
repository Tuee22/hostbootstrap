# Run-Model Taxonomy

**Status**: Authoritative source
**Supersedes**: the claim that `selectRunModel` is wired into `project up` and that `RunModel` is absent from Dhall
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)

> **Purpose**: Define the four useful execution-shape names, record the current definition-only selector
> honestly, and preserve the project chain as the sole executable representation.

## TL;DR

- `OneShot`, `HostNative`, `HostDaemon`, and `Cluster` are useful names for four execution shapes.
- The repository currently defines and tests `RunModel`, `RunModelKey`, and `selectRunModel`, but
  production `project up` does not call the selector. The demo selects concrete chain steps directly.
- `Core.dhall` currently exports a `RunModel` union. Therefore “a run model never appears in Dhall” is
  false; it is vocabulary even though the demo runtime config does not contain a run-model field.
- The target keeps `chain :: cfg -> [Step]` as the only executable plan. It removes the unconsumed
  parallel selector and Dhall literal rather than allowing topology, steps, and a run-model value to
  disagree.

## Current Status

`HostBootstrap.Harness` exposes:

```haskell
data RunModel = OneShot | HostNative | HostDaemon | Cluster

data RunModelKey = RunModelKey
  { keyTopology :: Topology
  , keyHostNative :: Bool
  }

selectRunModel :: RunModelKey -> RunModel
```

Unit tests cover the mapping, but no production interpreter consumes its result. The real demo path uses
`demoChainFor :: Substrate -> ProjectConfig -> [Step]`; that function selects VM/direct-container,
kind/nvkind, service, and host-daemon steps. `project up` interprets those concrete steps.

`Core.dhall` also exports `RunModel`. No current demo `<project>.dhall` field selects it, but its presence
in the public vocabulary means a downstream schema can declare it. This is a definition-only parallel
surface, not proof that runtime selection is wired.

Current status and cleanup ownership live in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## The Four Names

| Name | Execution shape | Current concrete examples |
|---|---|---|
| `OneShot` | A bounded container invocation that exits | `oneShotRunArgs`; definition-only `oneShotSeams` helper |
| `HostNative` | A host-native binary is built and executed on that host | the Python bootstrap handoff and host worker builds |
| `HostDaemon` | A long-running service/daemon process | config-selected `service run`, in a pod or host placement |
| `Cluster` | A kind/nvkind cluster plus deployed workloads | `deploy-kind`/`deploy-chart` and demo workload steps |

This table is a taxonomy. It does not imply that a `RunModel` value controls those paths today.

## Single-Representation Rule

The current forward representation is the project chain:

```haskell
chain :: cfg -> [Step]
```

The chain's rows currently determine:

- frame ids and their first-appearance descent order (while provider handoff details remain in the
  independently supplied `psFrameContext`);
- whether work is host-native, containerized, daemonized, or clustered;
- the order in which those operations run.

A current `Step` carries no resource envelope. Actions reload or close over config/context values, while
`psFrameContext` and resource slicing are separately supplied, so step identity and applied budget can
disagree. The target opaque `ProjectPlan` derives each operation's exact `ResourceSlice` alongside its
frame/dependencies/effect set; only then does the single representation determine resources.

A second configurable `RunModel` can contradict those facts. For example, a Dhall value could say
`Cluster` while the chain contains only a one-shot container, or a selector could return `HostNative`
while the interpreter still executes a container step. Keeping both values would violate the
single-representation contract.

The chain itself is not yet a validated single representation: public constructors permit an empty
chain, repeated/noncontiguous frames, duplicate/render-shadowing kinds, and `psFrameContext`/teardown
callbacks that can disagree with it. The target cleanup therefore consumes the same opaque
`ProjectPlan` used by render/apply/reverse traversal; it does not merely delete `RunModel` while leaving
those illegal shapes public.

The target therefore treats the four names as derived documentation/reporting labels, not configuration
or a second dispatch input:

```text
cfg + detected substrate
        │
        ▼
one validated chain/plan
        │
        ├─ interpreter consumes the plan
        └─ renderer may classify its concrete steps for display
```

If a future typed classifier is needed, it must consume the exact plan the interpreter will execute and
return a non-authoritative view. It must not independently choose behavior.

## Service And Daemon Shape

`service run` is a leaf process, not a second orchestrator. The effective project config selects a
project-owned service variant, and `ProjectSpec` maps it to a registered handler. In current core this
means an arbitrary `psServiceVariant :: cfg -> Either String String` function followed by a string lookup.
Core checks the primary context is a `ClusterService`/`Daemon` leaf, but it does not prove a service
field/capability/registry relation. The demo selector performs additional checks by convention, then its
handlers reopen the sibling config; selection and execution can therefore observe different bytes.

- An in-cluster service or daemon receives a projected ConfigMap and runs inside the controller-owned
  pod.
- A host daemon receives a host-resident projected config and is started/stopped by the surrounding
  project lifecycle.
- There is no `service down`; `project down`/`destroy` own the enclosing lifecycle.

The demo accelerator uses both placements depending on substrate. This behavior exists independently of
the unused `selectRunModel` value.

The target replaces that convention with
an internal existential
`SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
fields`. A validated
parent projects only a role-specific descriptive wire; the child verifies those exact mounted bytes
through the same finalized runtime spec and a separate verified secret bundle, then locally constructs
`ValidatedServiceRequest specDigest configId secretDigest fields service` under a fresh `configId`. The request inseparably contains
`RoleParams specDigest configId secretDigest fields service` filtered from the codec's hidden field row. The selected package
binds that request to a matching
`ServiceSelection scope specDigest planId configId secretDigest frame revision instanceId ServePhase
service effects` and closed
`ServiceProgram` handler; the selection proves the program's exact effect row is authorized by verified
placement and the one-use workload-instance/Serve command authority. The mounted wire contains
mandatory `FrameworkValidation` fields plus fields visible to that service; the handler's narrower
`RoleParams` contains only the latter. Framework-only metadata therefore cannot enter the payload, and
plan/build/deploy-only fields cross neither boundary. The handler receives neither the full config nor
raw `IO`/config-read capability. Before any acquisition, a one-use lifecycle-admission compare-and-swap
binds the measured process instance; a later Serve reservation prevents duplicate handler start. In the
final API the package and phase eliminators are not exposed: core-owned `runVerifiedRuntimeRole`
privately invokes `selectAndRunService` with identity-indexed ready handles, the Serve cursor, and the
inseparable retained receipt/lease package under masking. Selection failure, completion, typed failure, or
catchable shutdown all return an opaque `RoleAdvance ... ServePhase DrainPhase`; drain consumes the
retained package, attempts every independent release while aggregating failures, and is the sole
transition to Exit. Serve cannot expose bind/spawn to a handler. A restartable worker instead uses a
stable ready supervisor handle; only a prepared core transition may replace and reprobe its child.
Mutating effects first seal the exact target/arguments behind an operation key and call digest, then
require a matching prepared journal value minted from a Ready session and the retained live lease/fence.
The adapter receives that sealed call only through the prepared value and returns an indexed advance.
Prepare rejection/unknown and call-outcome unknown retain the sole session/resource package in typed
Drain/recovery states; only exact full-lineage reprobe can authorize same-key retry. A serve result cannot
be observed on a path that skips drain.

## Harness Relationship

The harness drives the real project chain:

```text
generate run config
  -> project up
  -> assert compiled cases
  -> project destroy
```

It does not need a separate run-model dispatch to bring up a parallel test topology. Current
Production/`.data`, ownership, and recursive-teardown defects are documented in
[harness workflow](harness_workflow.md); the presence of the four-name taxonomy does not close them.

## Target Cleanup

The owning development sprint must:

1. remove `RunModel` from `Core.dhall` unless a downstream decoded field has a documented, consumed
   contract;
2. remove the unconsumed `RunModelKey`/`selectRunModel` API, or replace it only with a read-only
   classifier over the exact executable plan;
3. prove no runtime/config field can disagree with the chain; and
4. update tests to exercise the chain constructors/interpreter rather than a detached selection table.

## Validation

- A source/API test proves there is no unconsumed runtime selector or configurable Dhall run-model
  literal.
- Plan/interpreter tests prove each supported topology is expressed by concrete steps and the same plan
  is rendered and executed.
- The harness continues to invoke the real `project up`, with no second per-model bring-up path.
- The Haskell quality gate and documentation validator pass.

## See Also

- [composition methodology](composition_methodology.md) — the current chain ordering and target opaque
  lifecycle plan.
- [harness workflow](harness_workflow.md) — the test transaction and its current gaps.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — concrete kind/nvkind operations.
- [build and run model](build_and_run_model.md) — host-native and container build paths.
