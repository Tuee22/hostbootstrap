# Execution-Shape Taxonomy

**Status**: Authoritative source
**Supersedes**: the detached harness selector and configurable Dhall execution union removed by Sprint 10.10
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)

> **Purpose**: Define four useful names for behavior already expressed by lifecycle steps while
> preserving the project chain as the sole executable representation.

## TL;DR

- `OneShot`, `HostNative`, `HostDaemon`, and `Cluster` are useful names for four execution shapes.
- They are documentation/reporting labels, not Haskell dispatch values or Dhall configuration.
- opaque validated `StepPlan` is the only current executable representation; the later
  `ProjectPlan` strengthens that same representation rather than introducing another selector.

## Current Status

Sprint 10.10 removed the detached Haskell selector, its selector-only topology/key types, the
definition-only one-shot and budget helpers that had no production call path, and the corresponding
Dhall union. A structural test checks both `HostBootstrap.Harness` and `Core.dhall` for that removed
parallel surface.

The real demo path contributes `demoChainFor :: Substrate -> ProjectConfig -> [Step]`; final plan
projection validates its exact order and `project up` interprets only the resulting `StepPlan`. No
project or test config carries a second execution-mode literal.

Current status and cleanup ownership live in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## The Four Names

| Name | Execution shape | Current concrete examples |
|---|---|---|
| `OneShot` | A bounded container invocation that exits | container/build lifecycle steps that terminate |
| `HostNative` | A host-native binary is built and executed on that host | the Python bootstrap handoff and host worker builds |
| `HostDaemon` | A long-running service/daemon process | config-selected `service run`, in a pod or host placement |
| `Cluster` | A kind/nvkind cluster plus deployed workloads | `deploy-kind`/`deploy-chart` and demo workload steps |

This table is a taxonomy. It does not imply that a separate value controls those paths.

## Single-Representation Rule

The current forward representation is the opaque validated plan:

```haskell
mkStepPlan :: [Step] -> Either StepPlanError StepPlan
```

The plan's rows determine:

- exact contiguous frame segments and descent order (while provider handoff details remain in the
  independently supplied `psFrameContext`);
- whether work is host-native, containerized, daemonized, or clustered;
- the order in which those operations run.

A current `Step` carries no resource envelope. General lifecycle actions may reload or close over
config/context values, while
`psFrameContext` and resource slicing are separately supplied, so step identity and applied budget can
disagree. The target opaque `ProjectPlan` derives each operation's exact `ResourceSlice` alongside its
frame/dependencies/effect set; only then does the single representation determine resources.

A second configurable execution selector could contradict those facts. For example, a Dhall value
could say `Cluster` while the chain contains only a one-shot container, or a detached classifier could
say `HostNative` while the interpreter still executes a container step. Keeping both values would
violate the single-representation contract.

Raw step/plan constructors are hidden. Validation rejects an empty plan, duplicate typed identities,
conflicting labels, noncontiguous frame returns, and invalid post-handoff order before effects; render,
frame selection, and apply consume the same `StepPlan`. Provider context and teardown are still separate
checked single-assignment callbacks, so the later `ProjectPlan`/receipt cleanup remains open.

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

`service run` is a leaf process, not a second orchestrator. The finalized project specification binds a
closed typed registry to the full config codec under one `specDigest`. Each definition contains one
typed structural projection, reflected `RoleCodec`, and handler; there is no arbitrary string selector.
Core checks the primary context is a `ClusterService`/`Daemon` leaf, canonically verifies one sibling
snapshot, mints an opaque typed request, and closes the handler over only that role's fields plus a safe
framework view. Demo handlers do not reopen the sibling config.

- An in-cluster service or daemon receives a projected ConfigMap and runs inside the controller-owned
  pod.
- A host daemon receives a host-resident projected config and is started/stopped by the surrounding
  project lifecycle.
- There is no `service down`; `project down`/`destroy` own the enclosing lifecycle.

The demo accelerator uses both placements depending on substrate. Its placement follows the configured
service and lifecycle steps.

Sprint 18.6 replaces the remaining raw handler action with an internal existential
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

## Completed Cleanup

Sprint 10.10:

1. removed the unconsumed Haskell selector/key/topology surface;
2. removed the corresponding union from `Core.dhall` and its admitted Haskell vocabulary codec;
3. removed definition/test-only helpers that had no typed-plan consumer; and
4. added exact vocabulary coverage plus a structural source test guarding the single-representation
   boundary.

## Validation

- A source/API test proves there is no unconsumed runtime selector or configurable Dhall execution
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
