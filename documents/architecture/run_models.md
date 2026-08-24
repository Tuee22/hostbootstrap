# Execution-Shape Taxonomy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [test harness and run ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)

> **Purpose**: Define four useful names for behavior already expressed by lifecycle steps while
> preserving the project chain as the sole executable representation.

## TL;DR

- `OneShot`, `HostNative`, `HostDaemon`, and `Cluster` are useful names for four execution shapes.
- They are documentation/reporting labels, not Haskell dispatch values or Dhall configuration.
- One admitted `ProjectPlan scope specDigest planId configId cfg` is the public Chain representation.
  `StepPlan` remains its opaque authoring and validation input, not a public execution boundary.

## Current Status

No detached Haskell selector, selector-only topology/key type, or configurable Dhall execution union exists.
A structural test checks both `HostBootstrap.Harness` and `Core.dhall` for that single-representation
boundary.

The real demo path contributes
`demoChainFor :: Substrate -> CanonicalProjectRoot scope rootId -> ProjectConfig scope -> [Step]`. Plan
admission validates that authored sequence and retains it as the exact non-empty `forward` projection of
one `ProjectPlan`. Public `HostBootstrap.Chain.renderChain` renders that full projection, while
`runChainFromFrame` interprets only its non-empty current-frame segment. No project or test config carries
a second execution-mode literal.

Production dispatch retains or reconstructs one exact `ProjectPlan` and uses it for dry rendering and
snapshot persistence/binding. Effectful root Up then admits the root-refined lifecycle context and enters the
Cabal-private `LifecycleEntry` producer/fixed interpreter, which alone derives the journal/current cursor,
calls generic `authorizeRootProject`, and reaches the lower public Chain. Its current-frame reverse verbs
derive work from that same exact representation. Harness does the same inside each generated-config ownership
bracket: it admits one `ProjectPlan (Harness projectId runId) ...`, packages that plan's fixed root-Up entry
interpreter and reverse action in an opaque `HarnessLifecycle`, and lets the engine invoke those actions
directly. No Harness lifecycle action
re-enters the CLI or a Production plan. These are call-site boundaries around one authored graph, not
alternate execution selectors. Nested
lifecycle entry fails closed until authenticated child admission and proof-complete traversal land; exact
`down`/`destroy` authorization belongs to
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

The [step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
owns the common plan/Chain foundation and Production command call site. The
[test-harness-and-run-ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
owns the Harness command consumer and assertion engine.

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

`StepPlan` validates the authored graph:

```haskell
mkStepPlan :: [Step] -> Either StepPlanError StepPlan
```

Admission then binds that graph to the exact scope, specification, configuration, root, and generative plan
identity. The public forward representation is:

```haskell
forward
  :: ProjectPlan scope specDigest planId configId cfg
  -> NonEmpty (PlannedStep scope planId configId (cfg scope))
```

The plan's rows determine:

- exact contiguous frame segments, descent order, and each frame's declared descent context (provider
  handoff plus child-config payload);
- whether work is host-native, containerized, daemonized, or clustered;
- the order in which those operations run.

Each `PlannedStep` retains the admitted node identity, frame, operation key, ordered dependency prefix,
projected operations, and action. Plan-owned resource and edge projections retain the same `scope` and
`planId`. Execution therefore derives these values from the admitted plan rather than asking a caller to
reconstruct a node or supply a parallel resource selection.

A second configurable execution selector could contradict those facts. For example, a Dhall value
could say `Cluster` while the chain contains only a one-shot container, or a detached classifier could
say `HostNative` while the interpreter still executes a container step. Keeping both values would
violate the single-representation contract.

Raw step and plan constructors are hidden. Validation rejects an empty plan, duplicate typed identities,
conflicting labels, noncontiguous frame returns, and any post-handoff suffix that does not unwind from
deeper participating frames toward the root before effects.
`renderChain` consumes the full `forward` projection of the admitted `ProjectPlan`; it neither opens a
second plan nor reads the hidden raw step representation.

`runChainFromFrame` consumes that same `ProjectPlan`, a matching
`CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase`, and a matching
`LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase`. It verifies their retained
frame, verb, and phase terms, checks the authority's retained protected-store origin, and compares the
cursor's retained acquisition project/store/broker origin to that authority before opening durable state.
It then selects a `NonEmpty` current-frame node segment and keeps the same plan indices
through execution descriptors, prepared operations, and the resource carrier. A step action's raw
`StepObservation` remains non-authorizing and plan-independent; `runPlannedStep` immediately wraps it
under the projected scope, plan, and configuration indices as opaque nominal
`PlannedStepObservation scope planId configId`, which is what Chain classifies, reports, and settles. The
authority's retained broker epoch and invocation identity name the operation session; the interpreter
allocates neither a second broker generation nor a caller-selected command identity. Every protected
entry also rereads the cursor's exact acquisition source and current durable row under that same entry;
an Execute cursor advanced to Teardown cannot authorize a later session, prepare, settlement, or close.
Recursive handoff derives the next frame and lift context from this plan's `DerivedTopology`, rather than
from a caller-supplied frame graph.

The taxonomy therefore treats the four names as derived documentation/reporting labels, not configuration
or a second dispatch input:

```text
cfg + detected substrate
        │
        ▼
one admitted ProjectPlan
        │
        ├─ renderer consumes the complete forward projection
        └─ interpreter consumes its authorized current-frame projection
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

The [service-runtime phase](../../DEVELOPMENT_PLAN/phase-22-service-runtime.md) replaces the remaining raw
handler action with an internal existential
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

The harness drives the real project lifecycle:

```text
own and generate run config
  -> interpret exact Harness plan forward
  -> assert compiled cases
  -> interpret that plan's reverse projection
  -> close only from settled-destroy evidence
```

It does not need a separate run-model dispatch to bring up a parallel test topology. `TestSuite` contains
only safety and assertion behavior; the private lifecycle constructor is available to the command and core
test components, not to downstream projects. The configured `durable-readback` case declares that it spans a
restart, while the engine owns the intermediate destroy, fresh invocation generation, exact rebind, and second
forward. The detailed authority path is documented in [harness workflow](harness_workflow.md).

## Single-representation guard

The source/API boundary admits no runtime selector or selector-only topology/key surface, `Core.dhall`
contains no execution-shape union, and exact vocabulary coverage plus a structural source test guard that
single representation.

## Validation

- A source/API test proves there is no unconsumed runtime selector or configurable Dhall execution
  literal.
- Plan/interpreter tests prove each supported topology is expressed by concrete steps, the full exact
  projection is rendered, and an authority/cursor-matched current-frame projection is executed.
- Production and Harness dispatch have no alternate plan/interpreter boundary. Harness retains one exact
  plan through generated-config ownership, and public Chain remains exact-plan-only.
- The Haskell quality gate and documentation validator pass.

## See Also

- [composition methodology](composition_methodology.md) — the current exact plan projections and chain
  ordering.
- [harness workflow](harness_workflow.md) — the test transaction and its current gaps.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — concrete kind/nvkind operations.
- [build and run model](build_and_run_model.md) — host-native and container build paths.
