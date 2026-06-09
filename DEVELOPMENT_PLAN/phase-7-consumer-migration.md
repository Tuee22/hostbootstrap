# Phase 7: Consumer Migration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Outline the migration of consumer projects onto `hostbootstrap-core` — first
> [`daemon-substrate`](https://github.com/Tuee22/daemon-substrate) and
> [`mcts`](https://github.com/Tuee22/mcts), with
> [`infernix`](https://github.com/Tuee22/infernix) and [`jitML`](https://github.com/Tuee22/jitML)
> as future work — each shipping one optparse binary that extends the core.

## Phase Status

**Status**: Active

`hostbootstrap-core` is a consumable Cabal package and
`documents/engineering/derived_project_standards.md` documents the consume-as-library pattern. This phase
reopens against the **three-level library hierarchy** contract: `hostbootstrap-core` (L0) ◄
`daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2), with `mcts` consuming L0 directly; each level extends
the four parallel streams (CLI tree, Dhall vocabulary, schema-gen registry, harness seams). The worked
consumer is now **`hostbootstrap-demo`** (see [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)),
which supersedes the thin `hostbootstrap-example` binary. The bulk of each consumer migration remains the
consuming repository's own work.

**Remaining Work** (reopened):
- Document the three-level hierarchy and the **two integration modes** — (1) freeze-import + the
  base-image `LABEL`/`ENTRYPOINT` contract (no Cabal dependency, e.g. `mcts`), and (2)
  `source-repository-package` + `runHostBootstrapCLI` extension (`daemon-substrate` and its apps) — in
  `documents/engineering/derived_project_standards.md` (see
  [development_plan_standards.md § P, § T](development_plan_standards.md)).
- Re-point the "worked example" references from `example/Main.hs` to `demo/` (the retirement lands in
  [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)).

## Phase Objective

Make `hostbootstrap-core` a consumable library. Each consumer ships one optparse-applicative binary
that calls `runHostBootstrapCLI "<project>" projectCommands` to extend the core command tree rather
than re-implementing core verbs (see [development_plan_standards.md § P](development_plan_standards.md)).
The consumer's binary is built **host-native** into `./.build/`; the project **container** it later
builds `FROM` the `hostbootstrap` base image gates on the project `check-code`.

## Sprints

### Sprint 7.1: daemon-substrate and mcts consumption [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/example/Main.hs`,
`documents/engineering/derived_project_standards.md`
**Docs to update**: `documents/engineering/derived_project_standards.md`, `system-components.md`

#### Objective

Confirm `hostbootstrap-core` is consumable as a `source-repository-package` dependency and that
`daemon-substrate` and `mcts` can extend the core command tree with their own subcommands.

#### Deliverables

- `hostbootstrap-core` exposed as a sibling-path / `source-repository-package` dependency consumers
  add to their `cabal.project`.
- The derived-project standard documents the host-native build into `./.build/`, the project
  container's `FROM` base image + `check-code` gate, and the `runHostBootstrapCLI` extension pattern.
- `daemon-substrate` (see https://github.com/Tuee22/daemon-substrate) and `mcts` (see
  https://github.com/Tuee22/mcts) each ship one binary extending the core; the consumer-side
  migration work is tracked in those repositories' own plans.

#### Validation

- `hostbootstrap-example --help` shows the core verbs (`ensure`, `config`, `cluster`) plus its own
  `greet` verb — the consumer extension contract, verified on the worked example binary.
- The consumer container building `FROM` the base image and passing its `check-code` gate is
  consumer-side work, exercised in each consumer repository.

#### Remaining Work

None on the `hostbootstrap` side. Consumer-side wiring (`daemon-substrate`, `mcts`) is tracked in
those repositories' own plans. (This sprint's `hostbootstrap-example` evidence is current-state; the
worked-example reference is re-pointed to `demo/` and the example binary retired in Phase 13, Sprint 13.7.)

### Sprint 7.2: infernix and jitML future migration (outline) [Done]

**Status**: Done
**Docs to update**: `documents/engineering/derived_project_standards.md`

#### Objective

Record the future-consumer outline so the contract stays honest while the migration is deferred.

#### Deliverables

- An outline noting that `infernix` (see https://github.com/Tuee22/infernix) is the source of the
  lifted host trio and migrates to consuming it back from `hostbootstrap-core`, and that `jitML` (see
  https://github.com/Tuee22/jitML) keeps Swift/Metal (Tart build-only) while reusing the CUDA and
  cluster logic.
- No `hostbootstrap`-side code obligation beyond keeping the core surface stable; the migration is
  future consumer work.

#### Validation

- Outline only; no mechanical gate. The outline below is recorded.

#### Remaining Work

None on the `hostbootstrap` side. `infernix` migrating to consume the host trio back from
`hostbootstrap-core`, and `jitML` reusing the CUDA/cluster logic while keeping Swift/Metal (Tart
build-only), are future consumer-repository work.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/derived_project_standards.md` - the consume-as-library pattern, the
  host-native build into `./.build/`, the project container's `FROM` base / `check-code` gate, and the
  `runHostBootstrapCLI` extension contract.

**Cross-references to add:**
- `system-components.md` notes `hostbootstrap-core` as a consumable dependency.
- Each consumer repository's own `DEVELOPMENT_PLAN/` carries the consumer-side migration phases.
