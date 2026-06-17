# Phase 17: Chain-Driven Test Surface And Context Introspection

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [00-overview.md](00-overview.md), [README.md](README.md)

> **Purpose**: Split the project's test surface into a `test init` writer and a root-only
> `test run <suite>|all` runner gated on a sibling `test.dhall` and **decoupled** from deploy, so
> `test run all` validates the persistent stack `project up` brings up; and make the read-only `context`
> command render the global lift composition (`topologyFrames` / `parentChain`) with the current frame
> highlighted.

## Phase Status

**Status**: Blocked

**Blocked by**: [phase-16-project-lifecycle-command.md](phase-16-project-lifecycle-command.md),
[phase-10-standardized-test-harness.md](phase-10-standardized-test-harness.md)

This phase realizes the chain-driven test surface and the read-only `context` introspection command of the
"chain is the project" model ([development_plan_standards.md § Z](development_plan_standards.md)). It rests
on two prerequisites that are not yet closed. Phase 16 owns the `project` lifecycle command, the recursive
chain interpreter, and the per-frame fail-fast handoff: `test run all` validates the **persistent** stack
that `project up` brings up, and the `context` command renders the same `topologyFrames` / `parentChain`
graph the interpreter descends, so the test and introspection surfaces here cannot land before that
lifecycle command and its `[Step]` interpreter exist. Phase 10 owns the standardized harness engine
(`HostBootstrap.Harness`: `runMatrix` over a `Seams` record, the per-case profile/path derivation, the
prefix delete-guard, budget-slicing, and the four run-models); that engine stays the **one lift-target
engine** ([development_plan_standards.md § W](development_plan_standards.md)) this phase exposes through the
split `test init` / `test run <suite>|all` command surface.

The new command surface is the **target** being built. The `project` command, the recursive interpreter,
and the split test surface are **not** implemented yet: the binary still ships the flat `test <case|all>`
verb, no `test.dhall` writer or gate exists, no `project up` persistent-stack command exists, and the
`context` surfaces are still folded into the `config schema` / `config show FILE` / `config path` / static
`config render` verbs that phase 15 reopens.

## Phase Objective

Land the chain-driven test surface and the read-only composition-introspection command:

- A `test init` command that runs only when a sibling project config already exists and writes the
  per-project `test.dhall` (which may carry test-specific configuration), mirroring `project init`.
- A `test run <suite>|all` command that runs one or more named test suites — where `all` is always a suite
  — is **root-only**, and **fails fast** when invoked without a `test.dhall` or from any non-root context.
- The test surface is **decoupled** from deploy: `project up` brings up a **persistent** stack and
  `test run all` validates that already-running stack rather than re-expressing deploy bring-up as a
  parallel chain of lifted operations beside the chain
  ([development_plan_standards.md § W](development_plan_standards.md)).
- The standardized harness (`HostBootstrap.Harness`) stays the one context-agnostic lift-target engine the
  split surface invokes; the test surface adds no `LiftContext` to the harness.
- A **read-only** `context` command that introspects the sibling `<project>.dhall` and renders the global
  lift composition (`topologyFrames` / `parentChain`) with the current frame highlighted, so an operator
  can see the whole `metal → VM → container → cluster` chain and where this binary lands in it. It performs
  no mutation; child-config creation is the `context-init` chain step inside `project up`
  ([development_plan_standards.md § Y](development_plan_standards.md)), not a `context` subcommand.

## Sprints

### Sprint 17.1: `test init` writer gated on an existing project config [Blocked]

**Status**: Blocked
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Blocked by**: Sprint 16.1, Sprint 16.4, Sprint 10.5
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

Add a `test init` command that mirrors `project init`: it runs only when a sibling project config already
exists and writes the per-project `test.dhall`, which may carry test-specific configuration over the
project's reusable Dhall vocabulary.

#### Deliverables

- A `test init` subcommand on the surfaced core command tree
  ([development_plan_standards.md § P, § Z](development_plan_standards.md)) that fails fast unless a sibling
  `<project>.dhall` already exists, then writes `test.dhall` next to it.
- A `test.dhall` schema and writer reflected from the harness's decoder types so the schema cannot drift,
  carrying any test-specific configuration alongside the project's reusable Dhall vocabulary
  ([development_plan_standards.md § Q](development_plan_standards.md)).
- Idempotent re-init semantics consistent with `project init` (a `--force`/`--if-missing` family), with the
  writer the only surface that materializes `test.dhall`.

#### Validation

- Unit tests prove `test init` fails fast with exit code 1 when no sibling project config exists and writes
  a decodable `test.dhall` when one does.
- Schema round-trip tests prove the rendered `test.dhall` decodes back to the harness configuration type.
- `cabal test all` from `core/` and `poetry run python -m hostbootstrap.test_all` pass.

#### Remaining Work

All work is open. The `test.dhall` schema, the `test init` writer, and its gate on an existing sibling
project config are the **target** being built; the binary ships no `test.dhall` writer today. This sprint
is blocked until phase 16 lands `project init` and the sibling-config authority
([development_plan_standards.md § Y, § X](development_plan_standards.md)) and phase 10 splits the inherited
flat `test <case|all>` surface ([phase-10-standardized-test-harness.md](phase-10-standardized-test-harness.md)).

### Sprint 17.2: Root-only `test run <suite>|all` over the live stack [Blocked]

**Status**: Blocked
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Blocked by**: Sprint 17.1, Sprint 16.2, Sprint 10.6
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Add a `test run <suite>|all` command that runs one or more named test suites against the persistent stack
`project up` brings up, where `all` is always a suite, the command is **root-only**, and it fails fast
without a `test.dhall` or from any non-root context.

#### Deliverables

- A `test run <suite>|all` subcommand that resolves the requested suite (or the always-present `all` suite)
  from the project's non-empty `TestSuite` ([development_plan_standards.md § T](development_plan_standards.md))
  and drives it through `HostBootstrap.Harness` (`runMatrix` over the project's `Seams`).
- A **root-only** gate: the command fails fast with exit code 1 when invoked without a sibling `test.dhall`
  or from any non-root context, enforced through the binary context
  ([development_plan_standards.md § X, § Z](development_plan_standards.md)) so a VM-scoped or
  cluster-service copy of the binary refuses the run.
- **Decoupling** from deploy: `test run all` validates the already-running `project up` stack and does not
  re-run the chain or re-express deploy bring-up as a parallel set of lifted operations
  ([development_plan_standards.md § W](development_plan_standards.md)); the harness remains the one
  context-agnostic lift-target engine with no `LiftContext` added to it.

#### Validation

- Unit tests prove `test run <suite>` and `test run all` dispatch to the resolved suites, that `all` always
  resolves, and that an unknown suite name fails fast.
- Context-gate tests prove `test run` fails fast (exit code 1) with no side effects when `test.dhall` is
  absent or when the command runs from a non-root frame.
- Demo validation: with a `project up` stack standing, `test run all` reports the demo's report card
  (the `e2e-tabs` Playwright case included) against the live stack; `cabal test all` and
  `poetry run python -m hostbootstrap.test_all` pass.

#### Remaining Work

All work is open. The root-only `test run <suite>|all` runner, its `test.dhall`/root gate, and its
validation of the live `project up` stack are the **target**; the binary ships the flat coupled
`test <case|all>` verb today and no `project up` persistent stack exists to validate. This sprint is blocked
until Sprint 17.1 lands the `test.dhall` writer, phase 16 lands the `project up` persistent-stack
interpreter ([development_plan_standards.md § Y](development_plan_standards.md)), and phase 10 retires the
flat coupled surface ([phase-10-standardized-test-harness.md](phase-10-standardized-test-harness.md)).

### Sprint 17.3: Read-only `context` composition introspection [Blocked]

**Status**: Blocked
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Blocked by**: Sprint 16.3, Sprint 15.3, Sprint 15.4
**Docs to update**: `documents/architecture/binary_context_config.md`, `documents/engineering/dhall_topology.md`, `documents/operations/demo_runbook.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

#### Objective

Make `context` a **read-only** composition-introspection command that renders the global lift composition
with the current frame highlighted and performs no mutation.

#### Deliverables

- A `context` command that introspects the sibling `<project>.dhall` and renders the global compositional
  sequence of lifts — the `topologyFrames` frame graph and the `parentChain` links
  ([development_plan_standards.md § X, § Z](development_plan_standards.md)) — with the **current frame**
  highlighted, so the whole `metal → VM → container → cluster` chain and this binary's place in it are
  visible at a glance.
- Absorption of the former read-only inspection surfaces (`config schema`, `config show FILE`,
  `config path`, static `config render`) under `context`
  ([development_plan_standards.md § X](development_plan_standards.md)), leaving `context` and
  help/version and `project init` as the only entrypoints allowed without an existing sibling context.
- A **no-mutation** guarantee: `context` carries no child-config creation surface; minting a callee's child
  `<project>.dhall` is the `context-init` chain step inside `project up`
  ([development_plan_standards.md § Y](development_plan_standards.md)), tracked as a dissolved verb in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- Unit tests prove `context` renders the `topologyFrames` / `parentChain` composition with the current
  frame marked, runs without a writable filesystem effect, and exposes no child-config mutation.
- Tests prove `context` is one of the only entrypoints allowed without an existing sibling context and that
  the absorbed inspection surfaces (`schema` / `show` / `path` / static `render`) report through it.
- Demo validation: `context` against the demo configs renders the `metal → VM → container → cluster` chain
  with the running frame highlighted; `cabal test all` passes.

#### Remaining Work

All work is open. The read-only `context` introspection command, its absorption of the former `config`
inspection surfaces, and its no-mutation guarantee are the **target**; the binary still carries the
standalone `config schema` / `config show FILE` / `config path` / static `config render` verbs and the
dissolved `context create vm|container|service` mutation verb today. This sprint is blocked until phase 16
lands the `context-init` chain step and the recursive interpreter that owns child-config creation
([development_plan_standards.md § Y](development_plan_standards.md)) and phase 15 migrates the child-config
constructors and inspection surfaces off the dissolved verbs (Sprints 15.3, 15.4 of
[phase-15-binary-context-config.md](phase-15-binary-context-config.md)).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/harness_workflow.md` - the test split `test init` / `test run <suite>|all`,
  root-gated and `test.dhall`-backed, decoupled from deploy; the harness stays the one lift-target engine
  and `test run all` validates the live `project up` stack.
- `documents/architecture/binary_context_config.md` - the read-only `context` introspection command, its
  absorption of the former `config schema` / `config show FILE` / `config path` / static `config render`
  surfaces, and the no-mutation guarantee.
- `documents/architecture/dhall_generation.md` - `test.dhall` as parameters + context + witness over the
  reusable Dhall vocabulary; the read-only `context` rendering and the generated `context-init` step.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` - `test init` / `test run <suite>|all`, root-gated, gated on
  `test.dhall`, and decoupled from deploy.
- `documents/engineering/dhall_topology.md` - topology frames drive both the recursive chain and the
  read-only `context` rendering (`topologyFrames` / `parentChain`).

**Cross-references to add:**
- `00-overview.md`, `README.md`, `system-components.md`, and `development_plan_standards.md` (§ Z) name
  Phase 17 and link to the chain-driven test surface and the read-only `context` command.
- [phase-16-project-lifecycle-command.md](phase-16-project-lifecycle-command.md) (the `project` lifecycle
  command, the recursive `[Step]` interpreter, and the `context-init` step) and
  [phase-10-standardized-test-harness.md](phase-10-standardized-test-harness.md) (the harness engine and
  the split test surface) name Phase 17 as the owner of this new work.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) records the dissolved
  `config schema|show|path|render` and `context create vm|container|service` verbs absorbed by the
  read-only `context` command.
