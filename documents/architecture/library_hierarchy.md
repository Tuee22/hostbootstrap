# Library Hierarchy And The Four-Stream Extension Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md)

> **Purpose**: Describe the three additive Cabal library levels and the four-stream extension contract — one additive merge idiom per stream — that lets each level compose on the level below without shadowing or redefinition.

## TL;DR

- The reusable surface is a three-level Cabal library hierarchy: `hostbootstrap-core` (L0) ◄
  `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2). `mcts` and `hostbootstrap-demo` consume L0
  directly.
- Each level adds only its **delta** to four parallel streams, one additive merge idiom each: the
  **lift chain** (`chain :: RootConfig -> [Step]`, core + project steps), the **Dhall vocabulary**,
  the **schema-gen** `ConfigArtifact` registry, and the **test-harness** `Seams`.
- A project's primary CLI contribution is its lift **chain value**, not a set of new noun verbs:
  the core ships host-management step kinds and the project contributes its own step kinds into the
  same ordered `[Step]`.
- Every merge is additive: lower levels are appended/embedded/concatenated, never shadowed or
  redefined. A level only contributes steps, vocabulary, artifacts, and seams; it never rewrites the
  level below.
- The chain shape is the canonical model owned by
  [composition_methodology](composition_methodology.md); this document defers to it for the chain and
  the recursive `project up` interpreter and describes only how the four streams layer.

## The Three Library Levels

The hierarchy is a chain of pinned Cabal libraries, each importing the one below:

| Level | Library | Imports | Adds |
|-------|---------|---------|------|
| L0 | `hostbootstrap-core` | — | The host-management base: the `project`/`context`/`test`/`check-code` command surface, the core host-management `Step` kinds, the `Core.dhall` vocabulary, the `coreArtifacts` registry, and the composable-operation algebra + the recursive lift interpreter (see [composition_methodology](composition_methodology.md)). |
| L1 | `daemon-substrate` | L0 | The daemon run-model surface — the concrete business-logic composition primitives (roles over durable external stores) on top of core. |
| L2 | `jitML`, `infernix` | L1 | App-level step kinds, vocabulary, and artifacts on top of the daemon substrate. |

`mcts` and `hostbootstrap-demo` consume L0 directly — they take the core surface without the daemon
layer. The cross-repo levels are referenced by absolute URL, not relative link:
[daemon-substrate](https://github.com/Tuee22/daemon-substrate),
[jitML](https://github.com/Tuee22/jitML),
[infernix](https://github.com/Tuee22/infernix), and
[mcts](https://github.com/Tuee22/mcts).

A consumer integrates in one of two modes: a `source-repository-package` Cabal dependency that
extends the core via `runHostBootstrapCLI` (the four-stream contract below), or a freeze-import that
relies on the base-image `LABEL`/`ENTRYPOINT` contract with no Cabal dependency. The four-stream
contract governs the extending mode.

## The Four-Stream Extension Contract

A level composes on the level below through exactly four parallel streams. Each stream has one merge
idiom, and every idiom is **additive**: it appends or embeds the lower level's contribution and adds
a delta, so the lower surface is preserved verbatim.

### Stream 1 — The Lift Chain

The first stream is the project's lift **chain**: an ordered `[Step]` value
(`chain :: RootConfig -> [Step]`) that the core's recursive `project up` interpreter walks frame by
frame. A level merges by contributing its own step kinds into that single list; the core's
host-management step kinds (deploy-VM, `ensure`-X, copy-source, build-pb, build-image, context-init,
deploy-kind, deploy-chart, expose-port) stay in scope unchanged, and host and workload steps
interleave freely in one chain. This Step algebra is the reuse unit and the workload-extension seam.
The chain is the canonical model — its shape, the recursive/fractal interpreter, and the
fractal-bootstrap descent are owned by [composition_methodology](composition_methodology.md); this
stream describes only the additive merge.

The chain is threaded into the generic entrypoint through `ProjectSpec`:

```haskell
runHostBootstrapCLI progName (projectSpec chain testSuite checkCode artifacts)
```

The core command surface (`project init|up|down|destroy`, `context`, `test init|run`, `check-code`)
behaves identically whether invoked through the bare `hostbootstrap` binary or through any project
binary, except that project binaries must supply their non-empty `chain`, test suite, `check-code`
action, and artifact delta in `ProjectSpec`. See
[hostbootstrap_core_library](hostbootstrap_core_library.md) for the entrypoint signature. A project
contributes named step kinds, so a project cannot silently shadow a core step kind or a core
top-level verb.

- **WRONG**: a project re-implements VM bring-up or cluster deploy with its own top-level noun verb,
  intending to "extend" the core. This is wrong because it shadows the core step kind with a parallel
  verb — behavior then diverges across binaries and the append-only guarantee is broken; it also
  reintroduces a second representation the single-representation doctrine forbids.
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
projectSpec projectChain projectSuite projectCheckCode [ artifactOf @ProjectConfig "project" sampleProjectConfig ]
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

The fourth stream is the standardized test harness. A project supplies a non-empty `TestSuite` made from
its `Seams` value and case matrix; `ProjectSpec` threads that suite into the inherited `test` surface.
The harness is **implemented** — the standardized-test-harness phase
([development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)) — completing the
four-stream contract: every level extends the surface through exactly these four parallel, additive
streams.

## Why Four Parallel Streams

Splitting extension into four single-idiom streams keeps the hierarchy DRY: each concern (the lift
chain, vocabulary, schema, tests) has one place a level may add to and a clear "append, never shadow"
rule. A project that follows all four idioms inherits the entire lower surface for free and contributes
only its delta — most importantly its `chain` value, the steps that distinguish it. The per-stream
rules every derived project follows are catalogued in
[derived_project_standards](../engineering/derived_project_standards.md); the standards-level
statement of the contract lives in
[development_plan_standards § T](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Current Status

The reusable surface is implemented today as the chain stream and the recursive `project`
interpreter this document describes, real-run-validated end-to-end on real hardware:

- Stream 1 is implemented as the single contributed `chain :: RootConfig -> [Step]` value walked by
  the recursive `project up` interpreter, threaded through `ProjectSpec` (the demo's
  `demoChain :: ProjectConfig -> [Step]` in `demo/src/HostBootstrapDemo/Commands.hs`). The former
  flat `cluster`, `config init`, and `context create` mutation verbs are now core step kinds
  (deploy-kind/deploy-chart, the project-init lifecycle, and the context-init step); `ensure` is
  retained only as a hidden debug surface, alongside the demo's `vm`/`incus` debug-hatch verbs and its
  load-bearing `web` verb. The hand-written demo deploy chain (the old Op-based
  `demo/src/HostBootstrapDemo/Chain.hs`) is deleted in favor of the single `demoChain` representation.
  The `project` command and its recursive/fractal interpreter are **shipped and validated**: a single
  `project up` on Incus/Linux stood up the live persistent stack, and `project down` / `project
  destroy` tore it down with host `.data` preserved.
- Streams 2, 3, and 4 are implemented as described: the `Core.dhall` vocabulary import-and-extend
  idiom, the `coreArtifacts` registry concatenation, and the standardized test-harness `Seams`.
  Stream 3's renders/projections are surfaced through the read-only `context` command and the
  context-init step, and stream 4 is invoked through `test init` / `test run`, with the additive merge
  idioms unchanged.

`DEVELOPMENT_PLAN/` owns the migration status and closure criteria for the flat-verb → project-chain
move; reconcile any status claim here to it rather than treating this document as a parallel status
authority.
