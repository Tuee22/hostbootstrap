# Phase 10: Standardized Test Harness and Run-Models

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md), [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Land the one standardized Dhall-driven test harness (`runMatrix` over a `Seams` record,
> with isolated per-case profiles, the prefix delete-guard, and budget-slicing) and name the minimal set
> of four run-models the harness and the bootstrapper select between.

## Phase Status

**Status**: Done

`HostBootstrap.Harness` provides `runMatrix :: Seams env -> [Case] -> IO Report`, which drives the case
matrix, deriving an isolated per-case profile (`testCaseProfile` → `<project>-test-<case>` /
`./.test_data/<case>/`), running the body, and tearing down in a guaranteed `finally` (a body exception
is recorded as `Fail`, not leaked). Never-touch-production is mechanical: `guardTestDelete` refuses any
non-prefixed cluster name and the pure `teardown` partition keeps `.data` out of the removal set.
`sliceBudget` divides the budget across divisible cases by weight (`splitByWeight`, floor) while
indivisible (GPU) cases each get the full budget at concurrency 1. `selectRunModel` derives the four
run-models (`OneShot`/`HostNative`/`HostDaemon`/`Cluster`) from the collapsed selection key — never
declared in Dhall. The L0 `OneShot` model ships both the pure `oneShotRunArgs` argv and the real
`oneShotSeams` IO seam (wired through the resolved Docker tool like `cluster up`). `runMatrix` isolates a
throwing `seamSetup` to its own case by recording a `Fail` rather than crashing the matrix. The L0 engine,
pure cores, run-model selection, and setup-isolation behavior are implemented and unit-tested; the worked
demo exercises the container/cluster path in real runs. **That harness engine is still valid and stays the
one lift-target engine** (development_plan_standards § W); this phase is reopened only for the **command
surface** the engine is exposed through.

The shipped surface is a single `test <case|all>` verb (Sprints 10.5–10.6) coupled to whatever context
runs it and threaded through `ProjectSpec`. The "chain is the project" model (development_plan_standards
§ Y, § Z) changes that contract: the test surface splits into a `test init` writer and a
`test run <suite>|all` runner, both **root-only** and gated on a sibling `test.dhall`, and is **decoupled**
from deploy — `project up` brings up a **persistent** stack and `test run all` validates that running stack.
The split-surface command tree and its `test.dhall` gate are implemented and unit-tested
(`HostBootstrap.Command` `test init` / `test run <suite>|all` + `CLISpec`): `test init` writes the
per-project `<project>.test.dhall` gated on an existing project config; `test run <suite>|all` is
**root-only**, fails fast without a `test.dhall`, and drives the project's `TestSuite` through `runMatrix`;
the flat coupled `test <case|all>` verb is retired. The live-`project up`-stack validation behaviour is
exercised by the demo's real run ([phase-13](phase-13-hostbootstrap-demo.md)); the split surface co-owned
with [phase-17](phase-17-chain-driven-test-and-context-introspection.md) has landed.

## Remaining Work

None. The test surface is split into `test init` (writes the per-project `<project>.test.dhall`, gated on
an existing project config) and root-only `test run <suite>|all` (fails fast without `test.dhall`),
decoupled from deploy; the harness stays the one lift-target engine. The live-stack validation behaviour is
exercised by the demo's real run ([phase-13](phase-13-hostbootstrap-demo.md)).

## Phase Objective

Provide the reusable test workflow and the run-model contract (see
[development_plan_standards.md § S, T](development_plan_standards.md)). Isolation, the delete-guard, the
profile/path derivation, budget-slicing, and report aggregation live once in L0; the app supplies the
matrix; never-touch-production is mechanical and unit-tested.

## Sprints

### Sprint 10.1: `runMatrix` driver and per-case isolation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `system-components.md`

#### Objective

Land the matrix driver and the isolated per-case profile derivation.

#### Deliverables

- `runMatrix :: Seams env -> [Case] -> IO Report`. Per case: derive the `TestCase` profile (cluster name
  `<project>-test-<case>`, data root `./.test_data/<case>/`), render the per-case Dhall, run the body, and
  tear down in a guaranteed `finally`; aggregate a `Report`.

#### Validation

- `HarnessSpec` asserts the profile/path derivation and that teardown runs on a failing case body.

#### Remaining Work

None.

### Sprint 10.2: `guardTestDelete` and the never-touch-production invariant [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Make never-touch-production mechanical: a parameterized prefix delete-guard plus the data-preserving
teardown partition.

#### Deliverables

- `guardTestDelete :: Prefix -> ClusterName -> Either GuardError ClusterName` (the prefix is
  project-supplied); the test-profile teardown refuses any name not matching the prefix. The pure
  `teardown` partition keeps `.data` out of the removal set for both `down` and `delete`.

#### Validation

- `HarnessSpec` asserts a non-prefixed name is rejected (`guardTestDelete`); `LifecycleSpec` and
  `HarnessSpec` together assert `.data` is never in the removal set (the pure `teardown` partition for
  both `down` and `delete`). `cabal test` passes.

#### Remaining Work

None.

### Sprint 10.3: Budget-slicing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

Keep the matrix within the project ceiling.

#### Deliverables

- `sliceBudget` divides the budget across concurrent cases via `Budget/split`; `fitsBudget` is checked
  against the actual concurrent set. Divisible CPU cases split equally; GPU/indivisible cases run serially
  at full budget (driven by a per-case weight/`indivisible` field).

#### Validation

- A test asserts the concurrent slices sum within budget and a GPU case runs at concurrency 1.

#### Remaining Work

None.

### Sprint 10.4: The four run-models and the selection key [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/run_models.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Name the minimal run-model set and how it is selected.

#### Deliverables

- The four models — `OneShot` (build-if-needed + `docker run --rm [-it] [mounts]`, budget-capped),
  `HostNative` (host-native build + host exec), `HostDaemon` (long-running host service), `Cluster`
  (kind+Helm) — and the selection key `(verb x detected-substrate x library-layer x generated-topology)`,
  never declared in Dhall (`selectRunModel`). The L0 `OneShot` model ships the pure, budget-capped
  `oneShotRunArgs` (`docker run --rm [-it] --cpus/--memory [-v mounts] <image> <cmd>`) **and** the real
  `oneShotSeams` IO seam that runs it through the resolved Docker tool (wired like `cluster up`; live run
  is real-run); `defaultSeams` is the trivial pass-through for the bare binary's empty matrix.

#### Validation

- `HarnessSpec` asserts `selectRunModel` for all four models and that `oneShotRunArgs` is budget-capped,
  mount-bound (`:ro` on read-only), `-it` when interactive, and command-tailed. `run_models.md` documents
  the selection key. `cabal test` passes.

#### Remaining Work

None.

### Sprint 10.5: `test` and `check-code` verbs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/engineering/testing.md`, `documents/engineering/code_check_doctrine.md`

#### Objective

Put the `test` and `check-code` verbs on the core tree so every project binary inherits them:
`test` drives `runMatrix`, prints the report card, and exits non-zero when any selected case fails;
`check-code` is the fail-fast image-build gate whose action is supplied through `ProjectSpec`.

#### Command Surface

- `<project> test <case|all>` — drive `runMatrix` over the named case (or the whole matrix with
  `all`), print the report card, and fail the command when the report contains a failed case (the
  project matrix is threaded in via the `TestSuite` hook, Sprint 10.6). **Target surface:** this single
  coupled `test <case|all>` verb is being split into `test init` (writes the sibling `test.dhall`) and
  `test run <suite>|all` (root-only, gated on `test.dhall`), decoupled from deploy
  (development_plan_standards § Z).
- `<project> check-code` — the image-build gate; the body is project-defined and supplied through
  `ProjectSpec`. **Unchanged** by the chain refactor.

#### Deliverables

- Both verbs on the core tree, inherited by every project binary; `test` turns a failed report into a
  non-zero exit, and `check-code` runs the required project action fail-fast.

#### Validation

- `<project> test all` runs the matrix and exits non-zero on a seeded failed case; `<project> test
  <case>` runs one case (an unknown case exits non-zero); `<project> check-code` runs the supplied hook
  and exits non-zero on a seeded failure.

#### Remaining Work

The `check-code` verb is complete and stays as built. The `test` verb is split per § Z: `test init` writes
the per-project `<project>.test.dhall` (gated on an existing project config), and root-only
`test run <suite>|all` fails fast without a `test.dhall` and drives the matrix via `runSuiteSelection`; the
flat coupled `test <case|all>` verb is retired. Implemented in `HostBootstrap.Command` and covered by
`CLISpec`. The live-`project up`-stack validation behaviour is exercised by the demo's real run
([phase-13](phase-13-hostbootstrap-demo.md)).

### Sprint 10.6: Project test-matrix hook + `all` selector on the inherited `test` verb [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`
(`TestSuite`/`emptySuite`/`allCasesSelector`/`runSuiteSelection`),
`core/hostbootstrap-core/src/HostBootstrap/Command.hs` (`testCommand` parses the `CASE` argument),
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs` (`runHostBootstrapCLI` threads the project spec)
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`,
`documents/engineering/derived_project_standards.md`, `README.md`

#### Objective

Make the inherited `test` verb run a project's **own** case matrix, so project tests live under
`test` rather than a per-noun subcommand.

#### Command Surface

- `<project> test all` — run the whole supplied matrix and print the report card.
- `<project> test <case>` — run the single case with that id; an unknown id exits non-zero, listing
  the valid ids and `all`.

**Target surface:** this `test <case|all>` shape becomes `test run <suite>|all` under a `test run`
subcommand, paired with a `test init` writer; `all` stays always-a-suite, the runner becomes root-only and
`test.dhall`-gated (development_plan_standards § Z). The `TestSuite`/`runSuiteSelection`/`ProjectSpec`
threading built here is **still valid** and is reused under the new `test run` verb.

#### Deliverables

- The `TestSuite` hook in `HostBootstrap.Harness`: an existential `TestSuite` over the per-project
  `Seams env` plus its `[Case]`, the reserved `allCasesSelector` (`"all"`, always available so a
  project may not name a case `all`), `runSuiteSelection` (selector → chosen cases → `runMatrix`), and
  `emptySuite` for the bare binary's explicit `runBareHostBootstrapCLI` path.
- `ProjectSpec` carries the non-empty `TestSuite`; `coreCommands`/`testCommand`/`runHostBootstrapCLI`
  thread it into the inherited verb, and `testCommand` parses a required `CASE` argument, fails fast on
  an unknown id, and exits non-zero when the selected report has failures.
- The bare `hostbootstrap` binary uses `runBareHostBootstrapCLI`; the demo binds `demoSeams`/`demoCases`
  through `demo/app/Main.hs`.

#### Validation

- `cabal build` (core library, bare binary, demo) succeeds. `HarnessSpec` covers `runSuiteSelection`:
  `all` → whole matrix, a named id → that one case, an unknown id → `Left` listing the valid ids +
  `all`, and `emptySuite all` → `test report: 0/0 passed` through the bare path. `CLISpec` covers
  `ProjectSpec` rejecting an empty project suite, `test all` exiting non-zero on a seeded failed case,
  and `check-code` running/failing through the supplied action. Live CLI surface:
  `hostbootstrap-demo --help` lists a top-level `test`; `hostbootstrap-demo vm --help` no longer lists
  `test`; `hostbootstrap-demo test bogus` exits non-zero.

#### Remaining Work

The `TestSuite` existential, `allCasesSelector`/`runSuiteSelection`, `emptySuite`, and the `ProjectSpec`
threading carry over unchanged. The selection is now exposed under `test run <suite>|all` (a `test run`
subcommand) paired with the `test init` writer, root-only and gated on a sibling `test.dhall` (§ Z),
implemented in `HostBootstrap.Command` and covered by `CLISpec`; the demo's lifted deploy step is updated
to `test run all` (`demo/src/HostBootstrapDemo/Chain.hs`).

### Sprint 10.7: Case-isolated setup and real seams [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/operations/demo_runbook.md`

#### Objective

Isolate a throwing `seamSetup` to its own case (not the whole matrix), and use real per-case assertions
in the worked demo.

#### Deliverables

- `runMatrix` `try`-wraps `seamSetup`: a setup exception fails that one case (there is nothing to tear
  down, since setup did not complete) instead of crashing the run.
- The worked demo supplies per-case seams that lift the cluster/deploy/e2e steps into the project
  container and assert the workload.

#### Validation

- `HarnessSpec` asserts a throwing setup fails that case without crashing the matrix. `cabal test` passes.
  The real per-case assertions are exercised in the [demo](phase-13-hostbootstrap-demo.md)'s run.

#### Remaining Work

None. The harness `seamSetup`-in-`try` isolation is unit-tested; the demo's per-case seams are exercised
in the demo's live run.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - the four run-models matrix and the selection key.
- `documents/architecture/harness_workflow.md` - the per-case loop, the seam-split (L0 driver vs cluster
  seams vs app matrix), and budget-slicing.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` - rewritten to the standardized harness and the `test` verb.

**Cross-references to add:**
- `system-components.md` adds the `HostBootstrap.Harness` row and the `test`/`check-code` verbs.
- `documents/engineering/code_check_doctrine.md` states `check-code` is a project-defined body.
