# Library Hierarchy And The Extension-Stream Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)

> **Purpose**: Describe the three Cabal library levels and the implemented checked
> additive/single-assignment extension-stream contract.

## TL;DR

- `hostbootstrap-core` is a **library of composable tools with a fixed command surface**
  (`project` / `test` / `service` / `context` / `check-code`), **not** a CLI topology. There are
  **no per-project verbs**, and a `ProjectSpec` carries **no `ProjectCommand` deltas**.
- The reusable surface is a three-level Cabal library hierarchy: `hostbootstrap-core` (L0) ◄
  `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2). `mcts` and `hostbootstrap-demo` consume L0
  directly.
- The extension contract admits checked additive **streams**, one merge idiom each: ordered step
  fragments finalized as one `StepPlan`, the **Dhall vocabulary**, the
  **schema-gen** `ConfigArtifact` registry, the assertion-only **`TestSuite`**, and the **service handlers**
  (the `ServiceType` variants `service run` resolves). The command surface itself is never a stream.
- A project's primary contribution is its lift **chain value** plus its service handlers — never a new
  noun verb: the core ships host-management step kinds and the project contributes its own step kinds
  into the same ordered `[Step]`, and registers service handlers behind the fixed `service` verb.
- `addSteps`, `addArtifacts`, `addAssemblyInputs`, and `addServices` append without erasure.
  There is no lifecycle slot beside the plan: an acquiring step declares the effect that releases it
  with `reversedBy`. Raw `ProjectSpec`/`Step` constructors are hidden; plan validation
  enforces disjoint core/project identities, exact contiguous frame order, explicit reverse policy,
  exactly one declared descent per frame that has a successor, and at most one runnable reverse effect
  per step.
- The chain shape is the canonical model owned by
  [composition_methodology](composition_methodology.md); this document defers to it for the current-frame
  Chain and target recursive `project up` interpreter and describes only how the streams layer.

## The Three Library Levels

The hierarchy is a chain of pinned Cabal libraries, each importing the one below:

| Level | Library | Imports | Adds |
|-------|---------|---------|------|
| L0 | `hostbootstrap-core` | — | The host-management base: the fixed `project`/`test`/`service`/`context`/`check-code` command surface, the core host-management `Step` kinds, the `Core.dhall` vocabulary, the `coreArtifacts` registry, the service-handler registry, the pure Lift context, generic resolved-tool Lift, provider realizations, and exact plan/Chain interpreter (see [composition_methodology](composition_methodology.md)). It owns **no default config values**. One scope-aware restricted `psAssemble` is the structural default source for Production init and Harness variants; `psTestInit` separately creates the project's test config. |
| L1 | `daemon-substrate` | L0 | The daemon run-model surface — the concrete business-logic composition primitives (roles over durable external stores) on top of core. |
| L2 | `jitML`, `infernix` | L1 | App-level step kinds, vocabulary, and artifacts on top of the daemon substrate. |

`mcts` and `hostbootstrap-demo` consume L0 directly — they take the core surface without the daemon
layer. The cross-repo levels are referenced by absolute URL, not relative link:
[daemon-substrate](https://github.com/Tuee22/daemon-substrate),
[jitML](https://github.com/Tuee22/jitML),
[infernix](https://github.com/Tuee22/infernix), and
[mcts](https://github.com/Tuee22/mcts).

Inside the L0 package, `harness-lifecycle-internal` is a private Cabal component rather than another
extension level. It exposes `HostBootstrap.Harness.Lifecycle.Internal` only to the main library and its
own test suite. The component owns the opaque `HarnessLifecycle` constructor: command code packages the
common forward/reverse actions retained from one exact Harness plan, while engine tests can construct a
controlled fixture. A downstream package cannot depend on that private component or manufacture a second
lifecycle path.

A hostbootstrap project integrates by taking a Cabal dependency on `hostbootstrap-core` (directly or
through a higher layer) and calling `runHostBootstrapCLI`. Importing a warm-store freeze alone merely
reuses dependency pins; the base image exposes no hostbootstrap integration `LABEL`, project binary, or
generic project `ENTRYPOINT`. The command surface itself is fixed and is never a stream.

## The Extension Streams

A level is intended to compose on the level below through five parallel streams. Each target stream has
one additive merge idiom. Additive streams append; teardown is a named checked single-assignment slot,
while each frame's descent is declared on the plan node that owns the boundary. The sections below state current enforcement.

### Stream 1 — The Lift Chain

The first stream is the project's lift **plan**: ordered `cfg -> [Step]` fragments validated into the
opaque `StepPlan` whose current-frame projection Chain interprets today and whose target recursive
`project up` interpreter walks frame by frame. `addSteps`
contributes new step kinds while preserving lower fragments; the core's
host-management step kinds (deploy-VM, `ensure`-X, copy-source, build-pb, build-image, context-init,
deploy-kind, deploy-chart, expose-port) stay in scope unchanged, and host and workload steps
interleave freely in one chain. This Step algebra is the reuse unit and the workload-extension seam.
The chain is the canonical model — its shape, the recursive/fractal interpreter, and the
fractal-bootstrap descent are owned by [composition_methodology](composition_methodology.md); this
stream describes only the additive merge.

The word “lift” in this stream names the project’s composed frame plan; it does not make the
`HostBootstrap.Lift` module an extension stream. L0 layers that reusable machinery internally: the
[Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)
owns pure `HostBootstrap.Lift.Context`, the
[ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) owns generic resolved-tool
Lift, the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns provider lifecycle realizations, and the
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
adds reachability/blob/registry helpers above the generic fold. A project adds steps to the plan; it does
not replace any of those dispatch layers.

The chain is threaded into the generic entrypoint through `ProjectSpec`:

```haskell
runHostBootstrapCLI progName projectSpec
```

The core command surface (`project init|up|down|destroy`, `test init|run`, `service init|schema|run`,
`context`, `check-code`) shares one parser and dispatch shape between the bare `hostbootstrap` binary and
project binaries. Behavior is intentionally different: the bare entrypoint supplies minimal empty/no-op
project behavior. A project entrypoint must finalize a non-empty test suite and step contribution and
one teardown projection; artifacts, inputs, typed step identities, and
services are duplicate-checked, and the plan must declare exactly one descent per frame that has a
successor. See
[hostbootstrap_core_library](hostbootstrap_core_library.md) for the entrypoint signature. A project can
never add or shadow a core top-level verb or typed core step identity; presentation labels do not select
behavior.

- **WRONG**: a project re-implements VM bring-up or kind cluster deploy with its own top-level noun
  verb, intending to "extend" the core. This is wrong because it shadows the core step kind with a
  parallel verb — behavior then diverges across binaries and the append-only guarantee is broken; it
  also introduces a second representation the single-representation doctrine forbids.
- **RIGHT**: the project supplies a typed delta whose identifiers are disjoint from core and
  whose frames extend the validated plan; the append combinator preserves lower steps, and construction
  rejects a duplicate or invalid frame return before dispatch.

### Stream 2 — Dhall Vocabulary

The Dhall vocabulary merges by importing the lower vocabulary and binding it, then defining new types
and functions that reference it:

```dhall
let C = ./Core.dhall
```

A higher vocabulary layer (`Daemon.dhall` at L1, `App.dhall` at L2) embeds `C` and extends it; it
never re-declares the L0 types. See [dhall_generation](dhall_generation.md) for the
static/context/generated Dhall model and the three-vocabulary layering.

- **WRONG**: `Daemon.dhall` copies the `Budget` record definition so it can "add a field". This is
  wrong because the copy can drift from `Core.dhall` `Budget`, the Haskell encoder declaration used for
  generated schema text, and the separately derived decoder; there are now multiple `Budget` shapes
  claiming to be canonical.
- **RIGHT**: `Daemon.dhall` writes `let C = ./Core.dhall` and refers to `C.Budget`, defining only its
  own new records on top.

### Stream 3 — Schema-Gen Registry

The schema-generation stream is assembled by core concatenating `coreArtifacts` with the project
artifact **delta** passed to `projectSpec`:

```haskell
addArtifacts
  [artifactOf "projectWidget" projectWidgetCodec sampleProjectWidget]
  (projectSpec projectSuite projectCheckCode [] testConfigCodec projectTestInit projectAssemble)
```

The read-only `context` surface then prints the transitive union of the in-scope schemas and
materializes static example renders from the same registry. `ConfigArtifact` construction is opaque:
each entry requires one admitted codec that owns both its schema and render. The project-local `cfg`
schema remains the separate `service schema` surface. Runtime child projection/delivery is separate from
this registry and is currently split among the composite bootstrap, the plan-declared descent, and
deployment seams. See
[config_generation](../engineering/config_generation.md).

- **WRONG**: a project passes `coreArtifacts ++ projectArtifacts` as its `ProjectSpec` argument. This
  is wrong because `HostBootstrap.Command` already prepends `coreArtifacts`, producing duplicates.
- **RIGHT**: pass only the project artifact delta. Core performs the one concatenation, and each delta is
  built through an opaque validated codec so its printed schema cannot be unrelated text.

### Stream 4 — Test-Harness Seams

The fourth stream is the standardized test harness. A project supplies a non-empty `TestSuite` — a five-field
existential (safety precondition, assertion-environment opener, case matrix, per-case assertion, and
post-reverse absence assertion); `ProjectSpec` threads that suite into the inherited `test` surface. The
`Seams`/`runMatrix` engine is built internally by the harness (`assertSeams`), not supplied by the project.
The harness **drives the real project plan**: it **generates** the run's `<project>.dhall` functionally
through the Harness request of the project's single restricted `psAssemble`, under fresh run authority
and the matching mapped codec, admits one exact `ProjectPlan (Harness projectId runId) ...`, and interprets
its hidden fixed root-Up entry and exact reverse projection. The entry alone invokes the lower Chain. It
never shells the lifecycle CLI, and project
assertions receive no lifecycle action. A suite may carry **more than one config variant** (the demo's
two-message run); the harness stands each exact plan up, asserts, and tears it down in turn. The
terminal reverse must produce settled-destroy closure evidence before the private ownership finalizer may
close the bound lease/mode; a callback returning successfully is not closure authority. The
standardized-test-harness phase
([test harness and run ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)) owns the harness.

### Stream 5 — Service Handlers

The fifth stream is the project's **typed service registry**. Each definition inseparably binds one
stable identity, structural config-to-role-field projection, reflected role-wire codec, and handler.
`addServices` appends registries; finalization rejects duplicate identities and hashes the closed
registry into the full project codec's `specDigest`. The fixed `service run` verb verifies one snapshot
and dispatches the typed request. The registry may be empty, in which case both Production and Harness
schema families report structured empty results.

## Why Parallel Streams

Splitting extension into single-idiom streams keeps the hierarchy DRY: each concern (the lift chain,
vocabulary, schema, tests, service handlers) has one place a level may add to and a clear "append, never
shadow" rule. A project that follows the idioms inherits the entire lower surface for free and contributes
only its delta — most importantly its `chain` value, the steps that distinguish it. The per-stream
rules every derived project follows are catalogued in
[derived_project_standards](../engineering/derived_project_standards.md); the standards-level
statement of the contract lives in
[development_plan_standards § T](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Current Status

The reusable surface is the chain stream and the recursive `project` interpreter this document
describes, exercised end-to-end on real hardware:

- Stream 1 is the ordered set of additive step fragments resolved to one opaque `StepPlan`, consumed by
  the current-frame Chain and intended for the recursive `project up` interpreter, and threaded through
  finalized `ProjectSpec`. Under the generic model
  (§ BB), fragments are `cfg -> [Step]` over
  a project's own config type `cfg`; the demo instantiates `cfg = ProjectConfig` through the
  substrate-selected `demoChainFor :: Substrate -> ProjectConfig -> [Step]` in
  `demo/src/HostBootstrapDemo/Commands.hs`. The core ships
  the host-management step kinds (deploy-VM, the project-init lifecycle, context-init, deploy-kind,
  deploy-chart, expose-port) and the demo interleaves its own step kinds (deploy-minio, deploy-registry,
  push-image, accelerator-daemon placement)
  into the same ordered `[Step]`. Every binary surfaces the same fixed tree — `project`, `test`,
  `service`, `context`, and `check-code` — and adds no verbs; the demo contributes its `web` and
  `accelerator` service variants and its VM/provider IO as chain steps. A single `project up` on Incus/Linux stands up the live
  persistent stack — deploy-kind → deploy-minio → deploy-registry → push-image → deploy-chart →
  expose-port, followed by the selected accelerator-daemon placement. Current native validation status
  belongs in the development plan. Its public representation rejects empty/noncontiguous plans and
  duplicate identities, and requires exactly one declared descent per frame that has a successor;
  teardown is still a checked single-assignment slot, and receipt-driven reverse traversal remains
  with the
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).
- Streams 2, 3, and 4 realize as described: the `Core.dhall` vocabulary import-and-extend idiom, the
  `coreArtifacts` registry concatenation, and the standardized assertion-only `TestSuite`. Stream 3's
  static renders surface through the read-only `context` command; child runtime projection is not a
  `ConfigArtifact` stream and is split across the current lifecycle seams.
  Stream 4 surfaces through `test init` and `test run`, which drive the standardized harness over the
  demo's case matrix; the harness generates each config variant and directly drives its exact
  Harness-scoped plan. The demo's same-run durable destroy/up/readback case remains open until Stream 4's
  engine can interpret a declarative two-phase assertion using a fresh lifecycle-invocation generation.

`DEVELOPMENT_PLAN/` owns the closure criteria for the extension-stream contract; reconcile any status claim
here to it rather than treating this document as a parallel status authority.
