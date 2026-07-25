# Phase 7: Consumer adoption

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Define how consumer projects adopt `hostbootstrap-core`: each consumer ships one
> optparse binary that enters the fixed core command tree and supplies typed behavior through
> `ProjectSpec`.

## Phase Status

**Status**: Done

`hostbootstrap-core` is a consumable Cabal package and
`documents/engineering/derived_project_standards.md` documents the consume-as-library pattern. The
supported hierarchy is `hostbootstrap-core` (L0) ◄ `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2),
with `mcts` and `hostbootstrap-demo` consuming L0 directly; each level extends the parallel behavior
streams (lift chain, Dhall vocabulary, schema-gen registry, typed tests, and service handlers), never the
command grammar. The worked consumer is
**`hostbootstrap-demo`** (see [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)). Consumer
repository adoption is tracked in each consumer's own repository. This phase is `Done`.

The implemented integration is a Cabal dependency (local or `source-repository-package`) plus
`runHostBootstrapCLI`. The former freeze-only base-image `LABEL`/`ENTRYPOINT` mode was an unrealized
documentation proposal and is removed by Phase 21.4.

## Phase Objective

Make `hostbootstrap-core` a consumable library. Each consumer ships one optparse-applicative binary
that calls `runHostBootstrapCLI "<project>" projectSpec` to enter the fixed core command tree rather than
re-implementing or appending verbs (see [development_plan_standards.md § P](development_plan_standards.md)).
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
consumers attach their behavior without adding subcommands.

#### Deliverables

- `hostbootstrap-core` exposed as a sibling-path / `source-repository-package` dependency consumers
  add to their `cabal.project`.
- The derived-project standard documents the host-native build into `./.build/`, the project
  container's `FROM` base image + `check-code` gate, and the `runHostBootstrapCLI` extension pattern.
- `daemon-substrate` (see https://github.com/Tuee22/daemon-substrate) and `mcts` (see
  https://github.com/Tuee22/mcts) each ship one binary entering the fixed core tree; the consumer-side
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

### Sprint 7.3: Three-level hierarchy and Cabal integration [Done]

**Status**: Done
**Implementation**: `documents/engineering/derived_project_standards.md`
**Docs to update**: `documents/engineering/derived_project_standards.md`

#### Objective

Document the three-level library hierarchy (`hostbootstrap-core` L0 ◄ `daemon-substrate` L1 ◄
`{jitML, infernix}` L2; `mcts` and `hostbootstrap-demo` L0-direct) and the implemented Cabal dependency +
`runHostBootstrapCLI` integration, including the parallel behavior streams (see
[development_plan_standards.md § P, § T](development_plan_standards.md)).

#### Deliverables

- The three-level hierarchy and extension-stream merge idioms are retained.
- The supported consumer path is a Cabal dependency plus `runHostBootstrapCLI`. The freeze-only
  `LABEL`/`ENTRYPOINT` proposal was never implemented; it is not part of this Done scope and Phase 21.4
  removes its stale governed prose.

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
