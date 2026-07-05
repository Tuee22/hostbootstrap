# Library Hierarchy And The Extension-Stream Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md)

> **Purpose**: Describe the three additive Cabal library levels and the extension-stream contract — one additive merge idiom per stream — that lets each level compose on the level below without shadowing or redefinition.

## TL;DR

- `hostbootstrap-core` is a **library of composable tools with a fixed command surface**
  (`project` / `test` / `service` / `context` / `check-code`), **not** a CLI topology. There are
  **no per-project verbs**, and a `ProjectSpec` carries **no `ProjectCommand` deltas**.
- The reusable surface is a three-level Cabal library hierarchy: `hostbootstrap-core` (L0) ◄
  `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2). `mcts` and `hostbootstrap-demo` consume L0
  directly.
- A project extends core only through additive **streams**, one merge idiom each: the **lift chain**
  (`chain :: cfg -> [Step]`, core + project steps), the **Dhall vocabulary**, the
  **schema-gen** `ConfigArtifact` registry, the **test seams** `Seams`, and the **service handlers**
  (the `ServiceType` variants `service run` resolves). The command surface itself is never a stream.
- A project's primary contribution is its lift **chain value** plus its service handlers — never a new
  noun verb: the core ships host-management step kinds and the project contributes its own step kinds
  into the same ordered `[Step]`, and registers service handlers behind the fixed `service` verb.
- Every merge is additive: lower levels are appended/embedded/concatenated, never shadowed or
  redefined. A level only contributes steps, vocabulary, artifacts, seams, and service handlers; it
  never rewrites the level below and never adds a command verb.
- The chain shape is the canonical model owned by
  [composition_methodology](composition_methodology.md); this document defers to it for the chain and
  the recursive `project up` interpreter and describes only how the streams layer.

## The Three Library Levels

The hierarchy is a chain of pinned Cabal libraries, each importing the one below:

| Level | Library | Imports | Adds |
|-------|---------|---------|------|
| L0 | `hostbootstrap-core` | — | The host-management base: the fixed `project`/`test`/`service`/`context`/`check-code` command surface, the core host-management `Step` kinds, the `Core.dhall` vocabulary, the `coreArtifacts` registry, the service-handler registry, and the composable-operation algebra + the recursive lift interpreter (see [composition_methodology](composition_methodology.md)). It owns **no default config values** — defaults live in a project's `psInit`. |
| L1 | `daemon-substrate` | L0 | The daemon run-model surface — the concrete business-logic composition primitives (roles over durable external stores) on top of core. |
| L2 | `jitML`, `infernix` | L1 | App-level step kinds, vocabulary, and artifacts on top of the daemon substrate. |

`mcts` and `hostbootstrap-demo` consume L0 directly — they take the core surface without the daemon
layer. The cross-repo levels are referenced by absolute URL, not relative link:
[daemon-substrate](https://github.com/Tuee22/daemon-substrate),
[jitML](https://github.com/Tuee22/jitML),
[infernix](https://github.com/Tuee22/infernix), and
[mcts](https://github.com/Tuee22/mcts).

A consumer integrates in one of two modes: a `source-repository-package` Cabal dependency that
extends the core via `runHostBootstrapCLI` (the extension-stream contract below), or a freeze-import that
relies on the base-image `LABEL`/`ENTRYPOINT` contract with no Cabal dependency. The extension-stream
contract governs the extending mode; the command surface itself is fixed and is never a stream.

## The Extension Streams

A level composes on the level below through five parallel streams. Each stream has one merge idiom, and
every idiom is **additive**: it appends or embeds the lower level's contribution and adds a delta, so the
lower surface is preserved verbatim.

### Stream 1 — The Lift Chain

The first stream is the project's lift **chain**: an ordered `[Step]` value
(`chain :: cfg -> [Step]`) that the core's recursive `project up` interpreter walks frame by
frame. A level merges by contributing its own step kinds into that single list; the core's
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
`context`, `check-code`)
behaves identically whether invoked through the bare `hostbootstrap` binary or through any project
binary, except that project binaries must supply their non-empty `chain`, test suite, service handlers,
`check-code` action, config builders, and artifact delta in `ProjectSpec`. See
[hostbootstrap_core_library](hostbootstrap_core_library.md) for the entrypoint signature. A project
contributes named step kinds, so a project cannot silently shadow a core step kind or a core
top-level verb.

- **WRONG**: a project re-implements VM bring-up or kind cluster deploy with its own top-level noun
  verb, intending to "extend" the core. This is wrong because it shadows the core step kind with a
  parallel verb — behavior then diverges across binaries and the append-only guarantee is broken; it
  also introduces a second representation the single-representation doctrine forbids.
- **RIGHT**: the project adds only new step kinds to its `chain` value and lets the core host-
  management steps pass through unchanged; the interpreter walks the one merged list and a shadow
  attempt is rejected before dispatch.

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
  wrong because the copy drifts from `Core.dhall` `Budget` and from the Haskell decoder that reflects
  to it; there are now two `Budget` shapes claiming to be canonical.
- **RIGHT**: `Daemon.dhall` writes `let C = ./Core.dhall` and refers to `C.Budget`, defining only its
  own new records on top.

### Stream 3 — Schema-Gen Registry

The schema-generation stream merges by concatenating each level's `ConfigArtifact` registry. L0
registers `coreArtifacts`; a project appends its own artifacts:

```haskell
withChain projectChain
  (projectSpec projectSuite projectCheckCode
      [ artifactOf @ProjectConfig "project" sampleProjectConfig ]
      projectInit projectTestInit projectTestConfig)
```

The read-only `context` surface then prints the transitive union of the in-scope schemas and
materializes static example renders from the same registry. Runtime child projections are minted by
the context-init step inside `project up`, deriving from the active local config. See
[config_generation](../engineering/config_generation.md).

- **WRONG**: a project builds a fresh registry that omits `coreArtifacts`, so the rendered schema no
  longer carries `budget`/`podResources`/`kindNode`. This is wrong because the core artifacts are part
  of the binary's accepted schema; dropping them makes the printed schema a lie about what the
  decoders accept.
- **RIGHT**: the project concatenates its artifacts onto `coreArtifacts`, so the union always carries
  the lower levels' schemas.

### Stream 4 — Test-Harness Seams

The fourth stream is the standardized test harness. A project supplies a non-empty `TestSuite` — a five-field
existential (safety precondition, bring-up, case matrix, per-case assertion, teardown); `ProjectSpec` threads
that suite into the inherited `test` surface. The `Seams`/`runMatrix` engine is built internally by the harness
(`assertSeams`), not supplied by the project.
The harness **drives the real `project up`**: it **generates** the run's `<project>.dhall` functionally via
the project's own `psTestConfig` (reusing the project-owned `psInit` builder, never shelling the CLI),
runs `project up`, asserts in-frame, then `project destroy`; it owns no second cluster-bring-up path. A
suite may carry **more than one config variant** (the demo's two-message run); the harness stands each up,
asserts, and tears it down in turn. The standardized-test-harness phase
([development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)) owns the harness.

### Stream 5 — Service Handlers

The fifth stream is the project's **service handlers**. A project defines its long-running roles as a Dhall
`ServiceType` ADT (`< Web : … | WorkloadOrchestrator : … >`) and contributes the matching handlers as a
registry threaded through `ProjectSpec`; the fixed `service run` verb dispatches on the variant. The
registry may be empty (not every project ships a service). This stream completes the extension contract:
every level extends the surface through these five parallel, additive streams — never a new command verb.

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
  a project's own config type `cfg`; the demo instantiates `cfg = ProjectConfig` (the demo's
  `demoChain :: ProjectConfig -> [Step]` in `demo/src/HostBootstrapDemo/Commands.hs`). The core ships
  the host-management step kinds (deploy-VM, the project-init lifecycle, context-init, deploy-kind,
  deploy-chart, expose-port) and the demo interleaves its own step kinds (deploy-registry, push-image)
  into the same ordered `[Step]`. Every binary surfaces the same fixed tree — `project`, `test`,
  `service`, `context`, and `check-code` — and adds no verbs; the demo contributes its `Web` service
  variant and its VM/provider IO as chain steps. A single `project up` on Incus/Linux stands up the live
  persistent stack — deploy-kind →
  deploy-registry → push-image → deploy-chart → expose-port ending at a live web service on
  `localhost:30080` — and `project down` / `project destroy` tear it down with host `.data` preserved.
- Streams 2, 3, and 4 realize as described: the `Core.dhall` vocabulary import-and-extend idiom, the
  `coreArtifacts` registry concatenation, and the standardized test-harness `Seams`. Stream 3's
  renders and projections surface through the read-only `context` command and the context-init step.
  Stream 4 surfaces through `test init` and `test run`, which drive the standardized harness over the
  demo's case matrix; the harness generates each config variant and drives the real `project up`.

`DEVELOPMENT_PLAN/` owns the closure criteria for the extension-stream contract; reconcile any status claim
here to it rather than treating this document as a parallel status authority.
