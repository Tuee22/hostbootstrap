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

**Status**: Done

**Reopened (2026-06-19) and closed (2026-06-20)**: `test run` drives the real `project up`, enforces the two
fail-fast safety preconditions, uses the L0 `.test_data` self-created-only delete-guard, and deletes only
what it created; `context` is uniform over all `<project>.dhall`s and read-only. Real-run-validated on a 16
GiB Apple-Silicon host (2026-06-20): `test run all` reported `3/3 passed` driving the same `project up` and
tearing down with `project destroy` (see `## Remaining Work`).

The chain-driven test surface and the read-only `context` introspection command are implemented and
unit-tested. `test init` writes the per-project `<project>.test.dhall` gated on an existing project config;
`test run <suite>|all` is root-only, fails fast without a `test.dhall`, and drives the project's `TestSuite`
through `runMatrix` (`HostBootstrap.Command` + `CLISpec`). The read-only `context` command renders the
global lift composition (`topologyFrames` / `parentChain`) with the current frame highlighted
(`HostBootstrap.Context.renderComposition` + `context inspect`, `ContextSpec`), absorbing the former
`config schema` / `config show FILE` / `config path` / static `config render` surfaces; it performs no
mutation. The standardized harness (`HostBootstrap.Harness`) stays the one context-agnostic lift-target
engine the split surface invokes (§ W).

`test run all` validates whatever stack is up via the harness seams; its validation of the **persistent**
`project up` stack (rather than an ephemeral per-case cluster) is exercised by the demo's real run
([phase-13](phase-13-hostbootstrap-demo.md)), and the recursive `project up` apply that brings up that
persistent stack is owned by [phase-16](phase-16-project-lifecycle-command.md).

## Remaining Work

[Phase 19](phase-19-generic-project-model.md) builds **forward** on this surface (the generic project
model, § BB): `test.dhall` becomes a thin override and `test run` *generates* the run's `<project>.dhall`
from it via the project-owned `psTestConfig`, and `test init` no longer requires a pre-existing
`<project>.dhall`. The superseded `test`-reuses-existing-config flow is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner. **This phase is
not reopened.**

**Native-Linux test parity — DONE (2026-06-21).** `test run all` now reports **`3/3 passed` on native
Incus/Linux** as well as Apple-Silicon/Lima. The fix generalized the self-reference lift's leaf
(`HostBootstrap.Lift`: `LiftLeaf = SelfSub | RawCmd`, `foldLeaf`, `liftLeaf`, `reachLeaf`; `foldLift` is now
the `SelfSub` special case), so a reachability check is a pure probe placed in the frame where the NodePort
is published (the VM). The demo's `pristine-bootstrap` / `web-build` assertions now fold their `curl` into
the VM frame (`incus exec <vm> -- curl …` / `limactl shell <vm> -- curl …`) like `e2e-tabs`, so they pass
on both providers with zero provider-specific assertion code; the ad-hoc `runInVMCapture` provider switch
was removed. Validated by `cabal test` (5 new `LiftSpec` `foldLeaf` cases) and a real `test run all` →
`3/3 passed` on this Incus host (2026-06-21).

Make the test surface **drive** `project up` and enforce the safety contract
(development_plan_standards § Z).

**Landed in code (2026-06-19), code-check-validated** (`cabal test all` green):

- The stack-driven `TestSuite` (phase-10) makes `test run` drive the real `project up` and tear down with
  `project destroy` — one bring-up per distinct test config, no second bring-up path. The demo wires
  `demoTestUp` (`project up`) / `demoTestDown` (`project destroy`) via the binary self-reference.
- The two **hard fail-fast safety preconditions** are enforced by `testSafetyPreconditions` and checked in
  `runSuiteSelection` before any bring-up: refuse if a production config already exists, refuse if a
  production cluster is running — either → no tests run (the demo's `demoTestSafety` supplies the
  cluster-running detector).
- The read-only `context` command already treats all `<project>.dhall`s uniformly and has **absorbed** the
  former `config schema` / `config show FILE` / `config path` / static `config render` surfaces (the
  `context` group is `inspect` / `show` / `schema` / `render` / `path`); the `context create` mutation verb
  is gone (re-homed as the `context-init` chain step). No mutation surface remains on `context`.

**Real-run-validated (2026-06-20):** on a 16 GiB Apple-Silicon host, `test run all` enforced the safety
preconditions, drove the real `project up`, asserted against the live stack in-frame (NodePort reachability
from the harness frame + the `e2e-tabs` Playwright run lifted into the VM frame), and tore down with
`project destroy` — **`3/3 passed`** ([phase-13](phase-13-hostbootstrap-demo.md)).

**`.test_data` self-created-only delete-guard landed (2026-06-20)** (co-owned with the L0 engine,
[phase-10](phase-10-standardized-test-harness.md)): `runSuiteSelection` wraps each run's bring-up / assert /
teardown in `HostBootstrap.Harness.withSelfCreatedTestData testDataRoot`, so `test run` creates `.test_data`
under the self-created-only guard and removes only what it created — never a `.test_data` (or `.data`) it
found (the pure `selfCreatedTestDataRemoval` is unit-tested). **The richer `test.dhall` also landed
(2026-06-20):** it is now a reflected record carrying `testSuites` + a `testResources` override (`TestConfig`
in `HostBootstrap.Config.Schema`); `test init` writes it and `test run` decodes and reports the test-config
resources before running (round-trip unit-tested, tracked in
[phase-10](phase-10-standardized-test-harness.md)). The phase scope is complete.

## Phase Objective

Land the chain-driven test surface and the read-only composition-introspection command:

- A `test init` command that writes the per-project `test.dhall` (which may carry test-specific
  configuration) without requiring a pre-existing sibling `<project>.dhall`.
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

### Sprint 17.1: `test init` writer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

Add a `test init` command that writes the per-project `test.dhall`, which may carry test-specific
configuration over the project's reusable Dhall vocabulary. Phase 19 later removed the pre-existing
`<project>.dhall` requirement, so this bootstrap path now works from a clean slate.

#### Deliverables

- A `test init` subcommand on the surfaced core command tree
  ([development_plan_standards.md § P, § Z](development_plan_standards.md)) that writes `test.dhall` next
  to the executable-sibling config path without requiring a production `<project>.dhall`.
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

Implemented and unit-tested (`HostBootstrap.Command` `test init` + `CLISpec`): `test init` writes the
per-project `<project>.test.dhall` (the selectable suites reflected from the threaded `TestSuite` — the
case ids plus `all` — so the file cannot drift from the matrix) and is gated on an existing sibling project
config, failing fast without one. Remaining: a richer `test.dhall` carrying test-specific configuration
beyond the suite list (today it is the Dhall list of suite ids).

### Sprint 17.2: Root-only `test run <suite>|all` over the live stack [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`, `demo/src/HostBootstrapDemo/Chain.hs`
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

Implemented and unit-tested (`HostBootstrap.Command` `test run` + `CLISpec`): `test run <suite>|all`
resolves the suite from the threaded `TestSuite` (or the always-present `all`) through `runSuiteSelection`,
is **root-only** (gated `HostOrchestratorCommand`), and fails fast with exit 1 without a `test.dhall`. The
demo's lifted deploy step is updated to `test run all` (`demo/src/HostBootstrapDemo/Chain.hs`). Remaining
(**real-run-gated**, § C): validating the live `project up` persistent stack rather than an ephemeral
cluster — the harness seams' full decoupling lands with the demo migration (Sprint 16.4) and a real run.

### Sprint 17.3: Read-only `context` composition introspection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`
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

Implemented and unit-tested: the pure `HostBootstrap.Context.renderComposition` renders the
`topologyFrames` / `parentChain` chain with the current frame highlighted and performs no mutation,
surfaced as the read-only `context inspect` command (`ContextSpec` covers the render exactly). Remaining:
absorbing the former `config schema` / `config show FILE` / `config path` / static `config render` surfaces
under `context` and retiring the `context create vm|container|service` mutation verb (the child-config
creation it did is re-homed as the `context-init` chain step inside `project up`, § Y) — landed with the
flat-verb removal once the demo migrates its chain (Sprint 16.4) so the tree stays green at each step.

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
