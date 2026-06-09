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
  optparse **CLI tree**, the **Dhall vocabulary**, the **schema-gen** `ConfigArtifact` registry, and
  the **test-harness** `Seams`.
- Every merge is additive: lower levels are appended/embedded/concatenated, never shadowed or
  redefined. A level only contributes verbs, vocabulary, artifacts, and seams; it never rewrites the
  level below.
- The CLI, vocabulary, and schema-gen streams are landed in `hostbootstrap-core`; the test-harness
  `Seams` stream is the fourth stream, planned for the standardized test harness
  ([Phase 10](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md)).

## The Three Library Levels

The hierarchy is a chain of pinned Cabal libraries, each importing the one below:

| Level | Library | Imports | Adds |
|-------|---------|---------|------|
| L0 | `hostbootstrap-core` | — | The host-management base: `ensure`/`cluster`/`config` verbs, the `Core.dhall` vocabulary, and the `coreArtifacts` registry. |
| L1 | `daemon-substrate` | L0 | The daemon run-model surface on top of core. |
| L2 | `jitML`, `infernix` | L1 | App-level verbs, vocabulary, and artifacts on top of the daemon substrate. |

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

### Stream 1 — optparse CLI Tree

The command tree merges by appending the project delta to the lower commands and handing the union to
the generic entrypoint:

```haskell
runHostBootstrapCLI progName (lower ++ delta)
```

The core verbs (`ensure …`, `cluster …`, `config …`) behave identically whether invoked through the
bare `hostbootstrap` binary or through any project binary. See
[hostbootstrap_core_library](hostbootstrap_core_library.md) for the entrypoint signature.

- **WRONG**: a project re-implements `config` or `cluster` with its own parser, intending to "extend"
  it. This is wrong because it shadows the core verb — the project's parser, not the core one, now
  handles the verb, so behavior diverges across binaries and the append-only guarantee is broken.
- **RIGHT**: the project adds only new `command "…"` entries to the delta and lets the core verbs
  pass through unchanged.

### Stream 2 — Dhall Vocabulary

The Dhall vocabulary merges by importing the lower vocabulary and binding it, then defining new types
and functions that reference it:

```dhall
let C = ./Core.dhall
```

A higher vocabulary layer (`Daemon.dhall` at L1, `App.dhall` at L2) embeds `C` and extends it; it
never re-declares the L0 types. See [dhall_generation](dhall_generation.md) for the
two-kinds/three-tiers/three-vocabulary model.

- **WRONG**: `Daemon.dhall` copies the `Budget` record definition so it can "add a field". This is
  wrong because the copy drifts from `Core.dhall` `Budget` and from the Haskell decoder that reflects
  to it; there are now two `Budget` shapes claiming to be canonical.
- **RIGHT**: `Daemon.dhall` writes `let C = ./Core.dhall` and refers to `C.Budget`, defining only its
  own new records on top.

### Stream 3 — Schema-Gen Registry

The schema-generation stream merges by concatenating each level's `ConfigArtifact` registry. L0
registers `coreArtifacts`; a project appends its own artifacts:

```haskell
projectArtifacts = coreArtifacts ++ [ artifactOf @ProjectConfig "project" sampleProjectConfig ]
```

`config schema` then prints the transitive union of the in-scope schemas, and `config render`
materializes the in-scope renders. See [config_generation](../engineering/config_generation.md).

- **WRONG**: a project builds a fresh registry that omits `coreArtifacts`, so `config schema` no
  longer prints `budget`/`podResources`/`kindNode`. This is wrong because the core artifacts are part
  of the binary's accepted schema; dropping them makes the printed schema a lie about what the
  decoders accept.
- **RIGHT**: the project concatenates its artifacts onto `coreArtifacts`, so the union always carries
  the lower levels' schemas.

### Stream 4 — Test-Harness Seams

The fourth stream is the standardized test harness, whose extension point is a `Seams` value each
level contributes to additively, in the same append idiom as the other three. The harness itself is
planned — it is the standardized-test-harness phase
([development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md)) — and is named
here so the four-stream contract is complete: every level extends the surface through exactly these
four parallel, additive streams.

## Why Four Parallel Streams

Splitting extension into four single-idiom streams keeps the hierarchy DRY: each concern (commands,
vocabulary, schema, tests) has one place a level may add to and a clear "append, never shadow" rule.
A project that follows all four idioms inherits the entire lower surface for free and contributes only
its delta. The per-stream rules every derived project follows are catalogued in
[derived_project_standards](../engineering/derived_project_standards.md); the standards-level
statement of the contract lives in
[development_plan_standards § T](../../DEVELOPMENT_PLAN/development_plan_standards.md).
