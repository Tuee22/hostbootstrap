# Library Hierarchy And The Extension-Stream Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md)

> **Purpose**: Describe the three Cabal library levels, the target one-additive-merge-idiom-per-stream
> contract, and the current APIs that still permit replacement or shadow-shaped values.

## TL;DR

- `hostbootstrap-core` is a **library of composable tools with a fixed command surface**
  (`project` / `test` / `service` / `context` / `check-code`), **not** a CLI topology. There are
  **no per-project verbs**, and a `ProjectSpec` carries **no `ProjectCommand` deltas**.
- The reusable surface is a three-level Cabal library hierarchy: `hostbootstrap-core` (L0) ◄
  `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2). `mcts` and `hostbootstrap-demo` consume L0
  directly.
- The target extension contract admits only additive **streams**, one merge idiom each: the **lift chain**
  (`chain :: cfg -> [Step]`, core + project steps), the **Dhall vocabulary**, the
  **schema-gen** `ConfigArtifact` registry, the **test seams** `Seams`, and the **service handlers**
  (the `ServiceType` variants `service run` resolves). The command surface itself is never a stream.
- A project's primary contribution is its lift **chain value** plus its service handlers — never a new
  noun verb: the core ships host-management step kinds and the project contributes its own step kinds
  into the same ordered `[Step]`, and registers service handlers behind the fixed `service` verb.
- Current APIs enforce only part of that target. `withServices` appends and core concatenates the
  project artifact delta, but `withChain`, `withFrameContext`, `withTeardown`, and
  `withServiceConfig` replace earlier values. Public `Step`/`StepKind` constructors also permit
  duplicate names, a project kind that renders like a core kind, and noncontiguous repeated frames.
  The opaque target constructors make append-only composition and disjoint identities structural.
- The chain shape is the canonical model owned by
  [composition_methodology](composition_methodology.md); this document defers to it for the chain and
  the recursive `project up` interpreter and describes only how the streams layer.

## The Three Library Levels

The hierarchy is a chain of pinned Cabal libraries, each importing the one below:

| Level | Library | Imports | Adds |
|-------|---------|---------|------|
| L0 | `hostbootstrap-core` | — | The host-management base: the fixed `project`/`test`/`service`/`context`/`check-code` command surface, the core host-management `Step` kinds, the `Core.dhall` vocabulary, the `coreArtifacts` registry, the service-handler registry, and the composable-operation algebra + the recursive lift interpreter (see [composition_methodology](composition_methodology.md)). It owns **no default config values**. Current `psInit`, `psTestInit`, and `psTestConfig` are independent project callbacks; the demo shares a helper by convention. The target project assembler is the only structural default-bearing path. |
| L1 | `daemon-substrate` | L0 | The daemon run-model surface — the concrete business-logic composition primitives (roles over durable external stores) on top of core. |
| L2 | `jitML`, `infernix` | L1 | App-level step kinds, vocabulary, and artifacts on top of the daemon substrate. |

`mcts` and `hostbootstrap-demo` consume L0 directly — they take the core surface without the daemon
layer. The cross-repo levels are referenced by absolute URL, not relative link:
[daemon-substrate](https://github.com/Tuee22/daemon-substrate),
[jitML](https://github.com/Tuee22/jitML),
[infernix](https://github.com/Tuee22/infernix), and
[mcts](https://github.com/Tuee22/mcts).

A hostbootstrap project integrates by taking a Cabal dependency on `hostbootstrap-core` (directly or
through a higher layer) and calling `runHostBootstrapCLI`. Importing a warm-store freeze alone merely
reuses dependency pins; the base image exposes no hostbootstrap integration `LABEL`, project binary, or
generic project `ENTRYPOINT`. The command surface itself is fixed and is never a stream.

## The Extension Streams

A level is intended to compose on the level below through five parallel streams. Each target stream has
one additive merge idiom. The current implementation reaches that rule for services, artifact
concatenation, and vocabulary by convention, but its function-valued setters and public step constructors
do not universally preserve the lower contribution. The sections below state the target rule and call
out current enforcement.

### Stream 1 — The Lift Chain

The first stream is the project's lift **chain**: an ordered `[Step]` value
(`chain :: cfg -> [Step]`) that the core's recursive `project up` interpreter walks frame by
frame. The intended merge contributes new step kinds into that single list while preserving the lower
plan; the core's
host-management step kinds (deploy-VM, `ensure`-X, copy-source, build-pb, build-image, context-init,
deploy-kind, deploy-chart, expose-port) stay in scope unchanged, and host and workload steps
interleave freely in one chain. This Step algebra is the reuse unit and the workload-extension seam.
The chain is the canonical model — its shape, the recursive/fractal interpreter, and the
fractal-bootstrap descent are owned by [composition_methodology](composition_methodology.md); this
stream describes only the additive merge.

The chain is threaded into the generic entrypoint through `ProjectSpec`:

```haskell
runHostBootstrapCLI progName projectSpec
```

The core command surface (`project init|up|down|destroy`, `test init|run`, `service init|schema|run`,
`context`, `check-code`) shares one parser and dispatch shape between the bare `hostbootstrap` binary and
project binaries. Behavior is intentionally different: the bare entrypoint supplies minimal empty/no-op
project behavior. A project entrypoint must supply a non-empty test suite, but current validation does
not require a non-empty chain or service registry and does not inspect function-valued callbacks. See
[hostbootstrap_core_library](hostbootstrap_core_library.md) for the entrypoint signature. A project
can never add or shadow a core top-level verb, but `ProjectStep String` can currently use the rendered
name of a core kind and `Step`/`StepFrame` constructors permit duplicate or noncontiguous frames.
`withChain` also replaces any previously attached chain instead of accepting a typed delta.

- **WRONG**: a project re-implements VM bring-up or kind cluster deploy with its own top-level noun
  verb, intending to "extend" the core. This is wrong because it shadows the core step kind with a
  parallel verb — behavior then diverges across binaries and the append-only guarantee is broken; it
  also introduces a second representation the single-representation doctrine forbids.
- **RIGHT (target)**: the project supplies a typed delta whose identifiers are disjoint from core and
  whose frames extend the validated plan; the append combinator preserves lower steps, and construction
  rejects a shadow before dispatch. Today this discipline is a consumer convention, not a guarantee of
  the public constructors.

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
withChain projectChain
  (projectSpec projectSuite projectCheckCode
      [ artifactOf @ProjectConfig "project" sampleProjectConfig ]
      projectInit projectTestInit projectTestConfig)
```

The read-only `context` surface then prints the transitive union of the in-scope schemas and
materializes static example renders from the same registry. The current `ConfigArtifact` constructor is
public and can pair arbitrary schema/render text; the target admits only opaque validated codec-backed
artifacts. Runtime child projection/delivery is separate from this registry and is currently split among
bootstrap/frame-context/deployment seams. See
[config_generation](../engineering/config_generation.md).

- **WRONG**: a project passes `coreArtifacts ++ projectArtifacts` as its `ProjectSpec` argument. This
  is wrong because `HostBootstrap.Command` already prepends `coreArtifacts`, producing duplicates.
- **RIGHT**: pass only the project artifact delta. Core performs the one concatenation. In the target,
  each delta is built through an opaque codec so its printed schema cannot be unrelated text.

### Stream 4 — Test-Harness Seams

The fourth stream is the standardized test harness. A project supplies a non-empty `TestSuite` — a five-field
existential (safety precondition, bring-up, case matrix, per-case assertion, teardown); `ProjectSpec` threads
that suite into the inherited `test` surface. The `Seams`/`runMatrix` engine is built internally by the harness
(`assertSeams`), not supplied by the project.
The harness **drives the real `project up`**: it **generates** the run's `<project>.dhall` functionally via
the project's own independent `psTestConfig` callback (the demo shares a helper with `psInit` by
convention; core does not), never shells the CLI,
runs `project up`, asserts in-frame, then `project destroy`; it owns no second cluster-bring-up path. A
suite may carry **more than one config variant** (the demo's two-message run); the harness stands each up,
asserts, and tears it down in turn. The standardized-test-harness phase
([development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)) owns the harness.

### Stream 5 — Service Handlers

The fifth stream is the project's **service handlers**. A project defines its long-running roles as a Dhall
`ServiceType` ADT (`< Web : … | WorkloadOrchestrator : … >`) and contributes the matching handlers as a
registry threaded through `ProjectSpec`; the fixed `service run` verb dispatches on the variant. The
registry may be empty (not every project ships a service). This stream completes the target extension
contract: every level adds through the five typed streams and never through a new command verb. The
current exceptions for other stream setters remain those documented above.

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

- Stream 1 is the single contributed chain value walked by the recursive `project up` interpreter and
  threaded through `ProjectSpec`. Under the generic model (§ BB) the chain is `chain :: cfg -> [Step]` over
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
  belongs in the development plan. Its public representation still admits empty/noncontiguous frames,
  duplicate/render-shadowing step kinds, and replacement of an earlier chain/context/teardown value.
- Streams 2, 3, and 4 realize as described: the `Core.dhall` vocabulary import-and-extend idiom, the
  `coreArtifacts` registry concatenation, and the standardized test-harness `Seams`. Stream 3's
  static renders surface through the read-only `context` command; child runtime projection is not a
  `ConfigArtifact` stream and is split across the current lifecycle seams.
  Stream 4 surfaces through `test init` and `test run`, which drive the standardized harness over the
  demo's case matrix; the harness generates each config variant and drives the real `project up`.

`DEVELOPMENT_PLAN/` owns the closure criteria for the extension-stream contract; reconcile any status claim
here to it rather than treating this document as a parallel status authority.
