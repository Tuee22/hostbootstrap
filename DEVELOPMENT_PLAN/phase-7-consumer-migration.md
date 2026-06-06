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

**Status**: Blocked

**Blocked by**: phase-6 (consumers extend the published base image and the baked core binary).

No code in this phase is written. This phase is an outline: the bulk of each consumer migration is
the consuming repository's own work, tracked in that repository's `DEVELOPMENT_PLAN/`. This phase
records `hostbootstrap`'s side of the contract.

## Phase Objective

Make `hostbootstrap-core` a consumable library. Each consumer ships one optparse-applicative binary
that calls `runHostBootstrapCLI "<project>" projectCommands` to extend the core command tree rather
than re-implementing core verbs (see [development_plan_standards.md § P](development_plan_standards.md)).
The consumer's container `FROM` the `hostbootstrap` base image, gates on the project `check-code`, and
copies its binary to `./.build/`.

## Sprints

### Sprint 7.1: daemon-substrate and mcts consumption [Blocked]

**Status**: Blocked
**Blocked by**: phase-6
**Docs to update**: `documents/engineering/derived_project_standards.md`, `system-components.md`

#### Objective

Confirm `hostbootstrap-core` is consumable as a `source-repository-package` dependency and that
`daemon-substrate` and `mcts` can extend the core command tree with their own subcommands.

#### Deliverables

- `hostbootstrap-core` exposed as a sibling-path / `source-repository-package` dependency consumers
  add to their `cabal.project`.
- The derived-project standard documents the `FROM` base image, the `check-code` gate, the copy to
  `./.build/`, and the `runHostBootstrapCLI` extension pattern.
- `daemon-substrate` (see https://github.com/Tuee22/daemon-substrate) and `mcts` (see
  https://github.com/Tuee22/mcts) each ship one binary extending the core; the consumer-side
  migration work is tracked in those repositories' own plans.

#### Validation

- A consumer binary shows the core verbs plus its own under `--help`.
- The consumer container builds `FROM` the base image and passes its `check-code` gate.

#### Remaining Work

- All of it; blocked on phase-6. Consumer-side wiring is the consumer repositories' work.

### Sprint 7.2: infernix and jitML future migration (outline) [Blocked]

**Status**: Blocked
**Blocked by**: sprint 7.1
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

- Outline only; no mechanical gate.

#### Remaining Work

- All of it; deferred future work, blocked on sprint 7.1.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/derived_project_standards.md` - the consume-as-library pattern, the `FROM`
  base / `check-code` / copy-to-`./.build/` flow, and the `runHostBootstrapCLI` extension contract.

**Cross-references to add:**
- `system-components.md` notes `hostbootstrap-core` as a consumable dependency.
- Each consumer repository's own `DEVELOPMENT_PLAN/` carries the consumer-side migration phases.
