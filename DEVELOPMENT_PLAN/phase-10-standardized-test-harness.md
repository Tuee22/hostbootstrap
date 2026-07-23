# Phase 10: Standardized Test Harness and Run-Models

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md), [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Land the one standardized Dhall-driven test harness (`runMatrix` over a `Seams` record) that
> **drives the real `project up`** under a test config, with the two fail-fast safety preconditions and the
> self-created-only delete-guard, and name the minimal set of four run-models.

## Phase Status

**Status**: Done

**Reopened 2026-07-21, CLOSED `Done` 2026-07-23 — legible lifecycle failure.** The harness owned the report
card, and it collapsed a bring-up failure to a message-less `ExitFailure 1`: `runSuiteSelection` rendered
`show err` on the `ExitCode` a `die` throws, so the Windows/WSL2 durable-share failure reported
`bring-up failed: ExitFailure 1` with no cause. Sprint 10.8 made bring-up failure legible — a structured
`LifecycleFailure` carried across the subprocess and harness boundary (the peer of `SafetyRefusal`), rendered
via `displayException`, plus the stream-then-die runner contract
([development_plan_standards](development_plan_standards.md) § CC). **CLOSED** on a live Windows/WSL2
`test run all` reporting **`8/8 passed`** (2026-07-23); the contract was additionally proven by an
intermediate **`6/8`** run whose two failures **named their cause** (`e2e failed (exit 1): the Accelerator
tab computes via the daemon`) rather than collapsing to `ExitFailure 1`. Also fixed the block-buffered gate
`.out` — `runSelfOrDie` now inherits the child's stdout, so a long recursive `project up` streams live.

**Reopened then closed (2026-07-05, cross-substrate reliability hardening).** The demo real-run gate surfaced
harness gaps in this phase's scope: teardown is **not** guaranteed on a bring-up failure or external kill (the
harness binds `env <- bringUp` outside its `finally`, so a failed `project up` leaks the VM/cluster and
aborts the remaining variants); the demo harness drives the **Production** profile (fixed NodePorts
30080/30500, fixed VM name) so isolation is only temporal, not spatial (core's isolated `TestCase`,
`publishesHostPorts=False`, is unused); and the "production cluster running" safety precondition probes the
**metal** kind, never the in-VM cluster, so it is a structural no-op for the demo topology. The fixes landed
(see `## Remaining Work`) and **closed 2026-07-05** by a live Windows/WSL2 `test run all` reporting
**`6/6 passed`**: the guaranteed-teardown engine ran the two message variants in turn (each `project up` →
assert → `project destroy`), the in-VM `productionClusterRunning` probe gated the run, and both variants tore
down cleanly.

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
throwing `seamSetup` to its own case by recording a `Fail` rather than crashing the matrix. The pure cores,
the run-model selection, and the setup-isolation behavior are implemented and unit-tested. The split test
surface — `test init` writes the per-project `<project>.test.dhall` gated on an existing project config;
root-only `test run <suite>|all` fails fast without a `test.dhall` and drives the project's `TestSuite`
through `runMatrix` — is implemented and unit-tested (`HostBootstrap.Command` + `CLISpec`); the flat coupled
`test <case|all>` verb is retired.

The "chain is the project" model (development_plan_standards § W, § Z) recasts the **engine**: the
standardized harness **drives the real `project up`** rather than standing up isolated per-case clusters
through `Seams` (`seamSetup`'s `clusterCreate`→`kind load`→`deployChart` mirror). Per **distinct test
configuration** the engine writes a test-specific `<project>.dhall`, runs `project up` over the project's
**own chain**, runs that config's case assertions in the frame appropriate to each (reusing the
self-reference lift, § U), and tears the stack down with `project destroy`. There is **one `project up` per
distinct test config**, and the engine owns **no second cluster-bring-up path** — it reuses the core pure
functional logic (the case matrix, the budget-slicing cores, the run-model selection, the delete-guard) and
the chain production uses. The engine recast to drive the real `project up` landed in code and is
real-run-validated; the last completed pre-accelerator `test run all` reported `6/6 passed` (phase-20's
second message variant brought the earlier single-variant `3/3` matrix to `6/6`; the dated 2026-06-20
`3/3` validation below stands). The current four-case/two-variant accelerator matrix requires `8/8` and
has no completed live result yet.

## Remaining Work

**Historical reopening 2026-07-05 — harness reliability. Code landed, code-check-validated, and
real-run-closed (§ C) 2026-07-05:**

- **Guarantee teardown on bring-up failure — landed.** `TestSuite`'s tear-down field is now `IO ()`
  (env-independent — `project destroy` re-detects the stack), so `runSuiteSelection` moves bring-up **inside**
  the guaranteed `finally`: a failed `project up` is caught (`tryAnyIO`), runs the same best-effort
  `project destroy`, and turns into a per-case `Fail` for that variant; each whole variant is isolated
  (`safeRunVariant`) so one variant's failure never aborts the remaining variants
  (`HostBootstrap.Harness.runSuiteSelection`; `HarnessSpec` covers failed-bring-up-still-tears-down).
- **Spatial isolation — landed (via mutual exclusion + an actually-firing probe).** The demo's cluster and
  its NodePorts live **inside** the VM, so a metal port is never a collision; two runs are made mutually
  exclusive by the existing sibling-`<project>.dhall` precondition (a second run sees the first's generated
  config and refuses) **and** by the managed-VM-existence refusal below, rather than racing. (Per-run offset
  ports/VM name for genuinely concurrent runs is intentionally not added — the demo serializes runs by
  design; noted in [phase-13](phase-13-hostbootstrap-demo.md).)
- **Real in-VM production-cluster safety probe — landed.** The demo's `productionClusterRunning` replaces the
  metal-only `kind get clusters` no-op: it checks metal kind **and** whether the managed provider VM exists
  (`substrateExists`), so an operator's live stack (or a crashed run's leftover VM) — whose in-VM cluster the
  metal probe could never see — now refuses the run (co-owned with
  [Phase 13](phase-13-hostbootstrap-demo.md)).

Code-check gate (2026-07-05): `cabal test all` (292) green; the demo `-Werror` build green. **Closed
(real-run, § C, 2026-07-05):** the guaranteed-teardown engine and the in-VM safety probe were exercised by
the live Windows/WSL2 `test run all` **`6/6`** run (two message variants, each brought up and torn down in
turn). **None remaining.**

[Phase 19](phase-19-generic-project-model.md) builds **forward** on the harness (the generic project
model, § BB): it *generates* the run's `<project>.dhall` from the `test.dhall` override via the
project-owned `psTestConfig` (reusing `psInit`) and deletes only matching run-owned bytes on teardown;
changed bytes remain in the reported locked quarantine. The
superseded `test`-reuses-existing-config flow is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner. **This phase built
forward through phase 19 and was not reopened for it; it is reopened 2026-07-21 for legible lifecycle failure
(Sprint 10.8, below).**

The split command surface (`test init` / `test run <suite>|all`) and the pure harness cores (the case
matrix, `sliceBudget`, `selectRunModel`, `guardTestDelete`, the data-preserving `teardown` partition, the
`seamSetup`-in-`try` isolation) are built, unit-tested, and stay valid.

**Engine recast landed in code (2026-06-19), code-check-validated** (`cabal test all` green, 224 tests):
the standardized harness no longer carries a second bring-up path. `HostBootstrap.Harness.TestSuite` is
recast into a **stack-driven** suite — `(safety-preconditions, bring-up, cases, per-case assertion,
tear-down)` — where bring-up drives the real `project up` and tear-down drives `project destroy` (the demo
wires these via the binary's self-reference, § U). `runSuiteSelection` enforces the two safety preconditions
(`testSafetyPreconditions`), brings the stack up once per distinct test config, runs the chosen cases'
assertions against that **one live stack** by reusing `runMatrix` (the kept per-case loop), and guarantees
`project destroy` via `finally`. The demo's `demoSeams` `clusterCreate → kind load → deployChart`
bring-up mirror is **deleted**; `demoTestSuite` drives `project up` instead. The pure cores
(`runMatrix`/`Seams`, `sliceBudget`, `selectRunModel`, `guardTestDelete`) are kept and still unit-tested.

**Recast engine real-run-validated (2026-06-20):** on a 16 GiB Apple-Silicon host, `test run all` drove the
recast engine end-to-end — safety preconditions → the real `project up` → the per-case assertions against
the one live stack (run in the frame appropriate to each, reusing the self-reference lift, § U) →
`project destroy` — reporting **`3/3 passed`** (`pristine-bootstrap` / `web-build` reachability + the
`e2e-tabs` Playwright run lifted into the VM frame), with **no second cluster-bring-up path**
([phase-13](phase-13-hostbootstrap-demo.md)). The engine reuses the kept pure cores (the case matrix,
`runMatrix`/`Seams`, budget-slicing, run-model selection, the delete-guard).

**`.test_data` self-created-only delete-guard landed (2026-06-20), code-check-validated** (`cabal test all`
green, 225 tests): the L0 engine now owns the run's `.test_data` lifecycle (§ Z). `HostBootstrap.Harness`
adds `testDataRoot` (the canonical `.test_data`), the pure `selfCreatedTestDataRemoval` (a directory the run
created is removed, a found one is preserved — mirroring never-delete-`.data`), and the
`withSelfCreatedTestData` bracket, which `runSuiteSelection` wraps the bring-up/assert/teardown in. So every
`test run` creates `.test_data` under the self-created-only guard and removes only what it created, never a
`.test_data` (or `.data`) it found. With the recast engine real-run-validated (`3/3 passed`, above) and the
pure cores (the `TestCase` profile rooting at `.test_data`, the data-preserving `teardown` partition,
`guardTestDelete`) unit-tested, the phase scope is complete.

**Richer `test.dhall` landed (2026-06-20), code-check-validated:** `test.dhall` is now a reflected record
`{ testSuites : List Text, testResources : { cpu, memory, storage } }` (`HostBootstrap.Config.Schema.TestConfig`,
`defaultTestConfig` / `renderTestConfig` / `decodeTestConfigFile`), carrying per-test **resource overrides**
alongside the selectable suites. `test init` writes it (seeded from the project config's resources, reflected
so it cannot drift); `test run` decodes it and reports the test-config resources before running. `SchemaSpec`
covers the render→decode round-trip. A consumer edits `testResources` to run its tests at a different budget
than production; the demo runs at its declared budget (its test resources equal its config's, since its full
lifecycle needs the full budget). Secrets are intentionally not carried as plaintext in `test.dhall` (the
credential-forwarding doctrine keeps secrets out of Dhall, § U).

The `project up` interpreter the engine drives is owned by
[phase-16](phase-16-project-lifecycle-command.md); the test surface that invokes the engine is
co-owned with [phase-17](phase-17-chain-driven-test-and-context-introspection.md).

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

### Sprint 10.8: Legible lifecycle failure [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/architecture/readiness.md`

#### Objective

Stop a bring-up failure from collapsing to a message-less `ExitFailure 1`. The cause must survive the
self-reference subprocess boundary and the harness catch and reach the report card.

#### Deliverables

- A structured `LifecycleFailure` exception (the peer of `SafetyRefusal`, with its own stderr marker for the
  subprocess round-trip) carrying the cause; `runSelfOrDie`'s generic-failure branch throws it instead of
  `die`, and `runSuiteSelection` renders it via `displayException` rather than `show err`
  (development_plan_standards § CC).
- The **stream-then-die** runner contract generalized from the existing image-build reporter / `check-code`
  runner: a runner that captures a child's output streams it (line-buffered, flushed) then dies with the exit
  context, rather than folding it into a stderr the recursive handoff and harness teardown unwind. The
  superseded stderr-folding `die` collapse is recorded in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- `cabal test` from `core/` — `HarnessSpec` asserts a bring-up `LifecycleFailure` round-trips to a rendered
  cause (not `ExitFailure 1`), the peer of the existing `SafetyRefusal` case.
- Real-run gate (§ C), jointly with phase-11 Sprint 11.9: the Windows/WSL2 `test run all` reports `8/8`, or a
  failing variant names its cause.

#### Remaining Work

**Code landed and static-validated (2026-07-22).** `HostBootstrap.Harness` gains a structured
`LifecycleFailure` (the peer of `SafetyRefusal`, with its own `lifecycleFailureMarker` for the subprocess
round-trip); `runSuiteSelection` renders a bring-up failure via `displayException` (the carried cause), not
`show err` (the `ExitFailure 1` collapse). The demo's `runSelfOrDie` is recast to **stream-then-die** —
the child's stdout is inherited (so a long recursive `project up` is observable live instead of block-
buffered), its stderr captured to detect the `SafetyRefusal` / `LifecycleFailure` markers and re-raise the
carried reason (no per-frame envelope accretion); `runOrDieStdin` throws a `LifecycleFailure` carrying the
failed step's output instead of a message-less `die`. The core `failChain` already re-emits the marker via
`show exc`, so the cause round-trips end to end. Static gate green: `cabal test all --ghc-options=-Werror`
**core 382** (new `HarnessSpec` case: a bring-up `LifecycleFailure` renders its cause, never a bare
`ExitFailure 1`, and leaks no marker) **+ demo 98** `-Werror`. **Real-run gate MET (§ C, 2026-07-23):** the
live Windows/WSL2 `test run all` reported **`8/8 passed`**; an intermediate `6/8` run's two failures each
named their cause legibly. **None remaining.**

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - the four run-models matrix and the selection key.
- `documents/architecture/harness_workflow.md` - the per-case loop, the seam-split (L0 driver vs cluster
  seams vs app matrix), budget-slicing, and the report card rendering a legible `LifecycleFailure` instead of
  `ExitFailure 1` (Sprint 10.8).
- `documents/architecture/readiness.md` - **(new)** the legible-failure contract (`LifecycleFailure`,
  stream-then-die) shared with the readiness discipline.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` - rewritten to the standardized harness and the `test` verb.

**Cross-references to add:**
- `system-components.md` adds the `HostBootstrap.Harness` row and the `test`/`check-code` verbs.
- `documents/engineering/code_check_doctrine.md` states `check-code` is a project-defined body.
