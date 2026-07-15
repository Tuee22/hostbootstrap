# Phase 7: Consumer Adoption

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Define how consumer projects adopt `hostbootstrap-core`: each consumer ships one
> optparse binary that extends the core command tree instead of re-implementing core verbs.

## Phase Status

**Status**: Done

`hostbootstrap-core` is a consumable Cabal package and
`documents/engineering/derived_project_standards.md` documents the consume-as-library pattern. The
supported hierarchy is `hostbootstrap-core` (L0) ◄ `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2),
with `mcts` and `hostbootstrap-demo` consuming L0 directly; each level extends the parallel extension streams
(CLI tree, Dhall vocabulary, schema-gen registry, harness seams). The worked consumer is
**`hostbootstrap-demo`** (see [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)). Consumer
repository adoption is tracked in each consumer's own repository. This phase is `Done`.

The three-level hierarchy and the **two integration modes** — (1) freeze-import + the base-image
`LABEL`/`ENTRYPOINT` contract (no Cabal dependency, e.g. `mcts`), and (2) `source-repository-package` +
`runHostBootstrapCLI` extension (`daemon-substrate` and its apps, and the `demo/` consumer) — are
**documented** in `documents/engineering/derived_project_standards.md` (Sprint 7.3; see
[development_plan_standards.md § P, § T](development_plan_standards.md)).

## Phase Objective

Make `hostbootstrap-core` a consumable library. Each consumer ships one optparse-applicative binary
that calls `runHostBootstrapCLI "<project>" projectSpec` to extend the core command tree rather than
re-implementing core verbs (see [development_plan_standards.md § P](development_plan_standards.md)).
The `ProjectSpec` supplies the project's extension streams — the lift chain (`withChain`), the
service-handler registry plus config selector (`withServices` / `withServiceConfig`; config-selected
`service run`), a non-empty test suite, the project
`check-code` action, and the project config-artifact delta; it adds no new verbs. The consumer's binary is built **host-native** into
`./.build/`; the project **container** it later builds `FROM` the `hostbootstrap` base image gates on the
project `check-code`.

## Sprints

### Sprint 7.1: daemon-substrate and mcts consumption [Done]

**Status**: Done
**Implementation**: `demo/app/Main.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
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
  adoption work is tracked in those repositories' own plans.

#### Validation

- `hostbootstrap-demo --help` shows the fixed core verbs (`context` / `project` / `test` / `service` /
  `check-code`) and **no** appended verbs — the demo extends the core through its chain (`withChain`), its
  service registry and config-selected `service run`, its test suite, and its `check-code` action, not new verbs — the
  consumer extension contract, verified on the worked `demo/` binary.
- The consumer container building `FROM` the base image and passing its `check-code` gate is
  consumer-side work, exercised in each consumer repository.

#### Remaining Work

None. Consumer-side wiring (`daemon-substrate`, `mcts`) is tracked in those repositories' own plans.
The worked-consumer evidence is the `demo/` binary.

### Sprint 7.2: L2 consumer adoption outline [Done]

**Status**: Done
**Implementation**: `documents/engineering/derived_project_standards.md`
**Docs to update**: `documents/engineering/derived_project_standards.md`

#### Objective

Record the L2 consumer adoption contract without adding `hostbootstrap`-side implementation work.

#### Deliverables

- `infernix` (see https://github.com/Tuee22/infernix) consumes host-management surfaces from
  `hostbootstrap-core`.
- `jitML` (see https://github.com/Tuee22/jitML) keeps Swift/Metal as headless host-build-only work
  (the bare-host Metal bridge, no build VM) while reusing CUDA and cluster logic from the shared
  hierarchy.
- No `hostbootstrap`-side code obligation beyond keeping the core surface stable.

#### Validation

- Outline only; no mechanical gate. The outline below is recorded.

#### Remaining Work

None. L2 adoption details are consumer-repository work.

### Sprint 7.3: Three-level hierarchy and the two integration modes [Done]

**Status**: Done
**Implementation**: `documents/engineering/derived_project_standards.md`
**Docs to update**: `documents/engineering/derived_project_standards.md`

#### Objective

Document the three-level library hierarchy (`hostbootstrap-core` L0 ◄ `daemon-substrate` L1 ◄
`{jitML, infernix}` L2; `mcts` and `hostbootstrap-demo` L0-direct) and the two integration modes a
consumer chooses between, so the derived-project contract states how each level extends the four
parallel streams (see [development_plan_standards.md § P, § T](development_plan_standards.md)).

#### Deliverables

- `derived_project_standards.md` gains a *three-level library hierarchy* section (the L0/L1/L2 table
  and the extension-stream merge-idiom table) and a *two integration modes* section: (1) freeze-import + the
  base-image `LABEL`/`ENTRYPOINT` contract (no Cabal dependency, e.g. `mcts`); (2)
  `source-repository-package` + `runHostBootstrapCLI` extension (`daemon-substrate` and its apps, and
  the `demo/` consumer).

#### Validation

- `cabal test` passes (the `HostBootstrap.DocValidator` gate keeps the doc's metadata, links, and
  structure conformant).

#### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/derived_project_standards.md` - the consume-as-library pattern, the
  host-native build into `./.build/`, the project container's `FROM` base / `check-code` gate, and the
  `runHostBootstrapCLI` extension contract.

**Cross-references to add:**
- `system-components.md` notes `hostbootstrap-core` as a consumable dependency.
- Each consumer repository's own `DEVELOPMENT_PLAN/` carries consumer-side adoption work.
