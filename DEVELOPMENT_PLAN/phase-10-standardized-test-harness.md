# Phase 10: Standardized test harness and execution shapes

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md), [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Land the one standardized Dhall-driven test harness (`runMatrix` over a `Seams` record) that
> **drives the real `project up`** under a test config, with the two fail-fast safety preconditions and the
> self-created-only delete-guard; retain run-model names only as a behavior taxonomy expressed by the
> project lifecycle plan, not as a parallel selector or Dhall field.

## Phase Status

**Status**: Active

**Reopened 2026-07-24.** Sprints 10.9–10.10 supersede the earlier Done assessment because path/cooperative locks
do not provide exclusive identity-bearing ownership and the complete concurrency/failure matrix is not
validated, while a detached Haskell selector and Dhall union formed an unconsumed parallel model beside
the chain. Sprint 10.10 removed that parallel surface on 2026-07-25. Sprint 10.9's prerequisites have all
landed; its remaining work is the production consumption and validation tranche shared with Sprint 16.6.
Historical run counts below do not close that ownership/concurrency gap.

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
**`6/6 passed`**: the in-process cleanup path ran the two message variants in turn (each `project up` →
assert → `project destroy`), the metal-cluster/managed-VM refusal gated the run, and both variants tore
down cleanly in that run.

The earlier `runMatrix :: Seams env -> [Case] -> IO Report` engine supplied definition-only per-case
profile/prefix and budget/one-shot helpers alongside its live `finally`-based loop. Repository search
found no lifecycle-plan consumer for those helpers, so Sprint 10.10 removed them with the detached
execution selector and Dhall union. The retained harness drives only the real project lifecycle plan,
owns its report and self-created-data bracket, and isolates a
throwing `seamSetup` to its own case by recording a `Fail` rather than crashing the matrix. The pure cores
and setup-isolation behavior are implemented and unit-tested. Historical
parser prose described a root-only suite selector and existing-config-gated `test init`; Phase 17.4 owns
the actual `test run <case-id>|all` and `test init` semantics.

The "chain is the project" model (development_plan_standards § W, § Z) recasts the **engine**: the
standardized harness **drives the real `project up`** rather than standing up isolated per-case clusters
through `Seams` (`seamSetup`'s `clusterCreate`→`kind load`→`deployChart` mirror). Per **distinct test
configuration** the engine writes a test-specific `<project>.dhall`, runs `project up` over the project's
**own chain**, runs that config's case assertions in the frame appropriate to each (reusing the
self-reference lift, § U), and tears the stack down with `project destroy`. There is **one `project up` per
distinct test config**, and the engine owns **no second cluster-bring-up path** — it reuses the core pure
functional logic (the case matrix and self-created-data guard) and the chain production uses. The engine
recast to drive the real `project up` landed in code and is
real-run-validated; the last completed pre-accelerator `test run all` reported `6/6 passed` (phase-20's
second message variant brought the earlier single-variant `3/3` matrix to `6/6`; the dated 2026-06-20
`3/3` validation below stands). Those are dated matrix snapshots, not current ownership/concurrency
closure.

## Remaining Work

**Current:** Sprint 10.9 is active. Sprints 5.7, 9.10, and 19.7–19.8 are complete, and Sprint 15.9's
prerequisite producer foundations have landed. Per-variant generative ownership, exact root/config
authority, immutable snapshot binding, close-failure propagation, and the crash-consistent
project/session transaction coordinator have landed. The remaining tranche owns
authenticated cross-process child admission, receipt-producing reconciler report rows, the live prepared
effect/terminal-close and abandoned-run recovery paths, and the corresponding concurrency/recovery matrix.
Sprint 16.6 supplies the production call-site producers this phase consumes. The dated closure records
below do not cover those remaining integration or race contracts.

**A live 2026-08-03 reproduction on Apple Silicon added a new item to that tranche and gave the known
bound-recovery item a real failure to point at.** An interrupted run's own generated sibling config makes
the next run refuse *before* the abandoned-run sweep can run, so the recovery machinery this sprint
already landed is unreachable in exactly the case it was built for. Both halves are recorded with the
sprint's own [Remaining Work](#sprint-109-exclusive-test-ownership-and-failure-isolation-active).

**Completed 2026-07-25:** Sprint 10.10 removed the detached selector/type, Dhall union/codec, and all
audited definition/test-only helpers with no plan consumer. The structural regression test, exact Dhall
vocabulary inventory, pinned formatter/linter on every changed Haskell file, full **379-test** core
`-Werror` suite, and demo workspace `-Werror` suite all pass.

**Historical reopening 2026-07-05 — harness reliability. Code landed, code-check-validated, and
real-run-closed (§ C) 2026-07-05:**

- **In-process teardown attempt after bring-up failure — landed.** `TestSuite`'s tear-down field is now
  `IO ()` (env-independent — `project destroy` re-detects the stack), so `runSuiteSelection` moves
  bring-up inside a `finally`: a caught failed `project up` (`tryAnyIO`) attempts the same best-effort
  `project destroy` and becomes a per-case `Fail`; `safeRunVariant` then continues with later variants
  when that cleanup path returns. This does not survive a hard kill or prove that cleanup acquired the
  identity it intends to delete. Sprint 10.9 owns durable recovery and receipt-driven cleanup.
- **Cooperative collision checks — landed.** The demo's cluster and its NodePorts live **inside** the VM,
  so a metal port is not the collision boundary. The sibling-`<project>.dhall` precondition usually
  serializes cooperating runs, and the managed-VM-existence refusal below catches already-visible state.
  Neither check is an atomic reservation: two starters can pass the observation before either writes, and
  a same-privilege actor can replace path state. Sprint 10.9 therefore remains the owner of authoritative
  project-mode exclusion, run identity, and receipt-bearing resource reservations.
- **Metal-cluster and managed-VM refusal — landed.** The demo's `productionClusterRunning` replaces the
  metal-only `kind get clusters` no-op: it checks metal Kind **and** whether the managed provider VM
  exists (`substrateExists`). A visible operator stack or crashed-run VM therefore refuses the run. The
  check does not inspect the cluster inside the VM and is not an atomic absence proof or exclusive lease;
  Sprint 10.9 owns that stronger gate (co-owned with [Phase 13](phase-13-hostbootstrap-demo.md)).

Code-check gate (2026-07-05): `cabal test all` (292) green; the demo `-Werror` build green. **Closed
(real-run, § C, 2026-07-05):** the in-process cleanup path and the metal-cluster/managed-VM refusal were exercised by
the live Windows/WSL2 `test run all` **`6/6`** run (two message variants, each brought up and torn down in
turn). **None remaining.**

[Phase 19](phase-19-generic-project-model.md) builds **forward** on the harness (the generic project
model, § BB): it *generates* the run's `<project>.dhall` from the `<project>.test.dhall` override via the
Harness request of the project-owned scope-aware restricted `psAssemble`; core enforces one structural
project-config assembly path. The harness deletes only bytes that still match the generated
payload under the current cooperative sidecar guard; changed bytes remain in the reported locked
quarantine. That byte match holds none of the four § EE ownership clauses and mints no
identity-bearing ownership receipt (Sprint 10.9). The
superseded `test`-reuses-existing-config flow is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner. **This phase built
forward through phase 19 and was not reopened for it; it is reopened 2026-07-21 for legible lifecycle failure
(Sprint 10.8, below).**

The split command surface (`test init` / `test run <case-id>|all`) and the live harness engine
(`TestSuite`/`runMatrix`, the data-preserving `teardown` partition, and `seamSetup`-in-`try` isolation)
are built and unit-tested. Sprint 10.10 removed the former definition/test-only compatibility helpers
after the repository audit found no real plan-owned call path.

**Engine recast landed in code (2026-06-19), code-check-validated** (`cabal test all` green, 224 tests):
the standardized harness no longer carries a second bring-up path. `HostBootstrap.Harness.TestSuite` is
recast into a **stack-driven** suite — `(safety-preconditions, bring-up, cases, per-case assertion,
tear-down)` — where bring-up drives the real `project up` and tear-down drives `project destroy` (the demo
wires these via the binary's self-reference, § U). `runSuiteSelection` enforces the two safety preconditions
(`testSafetyPreconditions`), brings the stack up once per distinct test config, runs the chosen cases'
assertions against that **one live stack** by reusing `runMatrix` (the kept per-case loop), and guarantees
`project destroy` via `finally`. The demo's `demoSeams` `clusterCreate → kind load → deployChart`
bring-up mirror is **deleted**; `demoTestSuite` drives `project up` instead. The pure cores
(`runMatrix`/`Seams`, `sliceBudget`, `guardTestDelete`) are kept and unit-tested.

**Recast engine real-run-validated (2026-06-20):** on a 16 GiB Apple-Silicon host, `test run all` drove the
recast engine end-to-end — safety preconditions → the real `project up` → the per-case assertions against
the one live stack (run in the frame appropriate to each, reusing the self-reference lift, § U) →
`project destroy` — reporting **`3/3 passed`** (`pristine-bootstrap` / `web-build` reachability + the
`e2e-tabs` Playwright run lifted into the VM frame), with **no second cluster-bring-up path**
([phase-13](phase-13-hostbootstrap-demo.md)). The engine reuses the kept pure cores (the case matrix,
`runMatrix`/`Seams`, and the delete-guard); `sliceBudget` remains definition/test-only.

**`.test_data` self-created-only delete-guard landed (2026-06-20), code-check-validated** (`cabal test all`
green, 225 tests): the L0 engine now owns the run's `.test_data` lifecycle (§ Z). `HostBootstrap.Harness`
adds `testDataRoot` (the canonical `.test_data`), the pure `selfCreatedTestDataRemoval` (a directory the run
created is removed, a found one is preserved — mirroring never-delete-`.data`), and the
`withSelfCreatedTestData` bracket, which `runSuiteSelection` wraps the bring-up/assert/teardown in. So every
`test run` creates `.test_data` under the self-created-only guard and removes only what it created, never a
`.test_data` (or `.data`) it found. With the recast engine real-run-validated (`3/3 passed`, above) and the
pure cores (the `TestCase` profile rooting at `.test_data`, the data-preserving `teardown` partition,
`guardTestDelete`) unit-tested, that dated self-created-data guard slice was complete.

**Historical richer `<project>.test.dhall` landing (2026-06-20), code-check-validated:** `<project>.test.dhall` was a reflected record
`{ testSuites : List Text, testResources : { cpu, memory, storage } }` (`HostBootstrapDemo.Config.TestConfig`,
`defaultTestConfig` / `renderTestConfig` / `decodeTestConfigFile`), carrying per-test **resource overrides**
alongside the selectable suites. `test init` writes it (seeded from the project config's resources, with
an admitted schema); `test run` decodes it and reports the test-config resources before running.
`SchemaSpec` covers the render→decode round trip, while closed Phase 8 Sprint 8.7 supplies
construction-time encoder/decoder type-expression equality. A consumer edits `testResources` to run its tests at a different budget
than production; the demo runs at its declared budget (its test resources equal its config's, since its full
lifecycle needs the full budget). Secrets are intentionally not carried as plaintext in `<project>.test.dhall` (the
credential-forwarding doctrine keeps secrets out of Dhall, § U).
Sprint 19.6 later removed the dead `testSuites` field; the current demo test config contains only
`testResources`, while typed case/variant selection lives in the validated Haskell `TestMatrix`.

The `project up` interpreter the engine drives is owned by
[phase-16](phase-16-project-lifecycle-command.md); the test surface that invokes the engine is
co-owned with [phase-17](phase-17-chain-driven-test-and-context-introspection.md).

## Phase Objective

Provide the reusable test workflow and execution-shape taxonomy (see
[development_plan_standards.md § S, T](development_plan_standards.md)). The live matrix loop,
self-created-data guard, and report aggregation live once in L0; the app supplies the matrix. Phase
10.9 makes never-touch-production mechanical and derives any effective per-run budget from the actual
plan. Sprint 10.10 removed the unused parallel execution representation.

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
  attempt teardown through `finally` for in-process exits/exceptions; aggregate a `Report`.

#### Validation

- `HarnessSpec` asserts the profile/path derivation and that teardown runs on a failing case body.

#### Remaining Work

None.

### Sprint 10.2: `guardTestDelete` and removal-set protection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Add two narrow, testable refusal rules: a parameterized prefix delete guard and a teardown partition that
does not enumerate the plan's data path.

#### Deliverables

- `guardTestDelete :: Prefix -> ClusterName -> Either GuardError ClusterName` (the prefix is
  project-supplied); the test-profile teardown refuses any name not matching the prefix. The pure
  `teardown` partition keeps `.data` out of the removal set for both `down` and `delete`.
- These checks validate caller-supplied names and a pure removal set; they do not prove exclusive
  ownership, prevent a time-of-check/time-of-use race, or make every production identity unreachable.
  Sprint 10.9 owns that stronger contract.

#### Validation

- `HarnessSpec` asserts a non-prefixed name is rejected (`guardTestDelete`); `LifecycleSpec` and
  `HarnessSpec` together assert `.data` is never in the removal set (the pure `teardown` partition for
  both `down` and `delete`). `cabal test` passes. This is evidence for the two narrow guards, not for
  authoritative ownership or global never-touch-production behavior.

#### Remaining Work

None.

### Sprint 10.3: Definition-only budget-slicing helper [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

Land and unit-test the pure budget-slicing helper. This historical sprint did not wire it into the live
matrix engine or prove that an applied workload fits the project ceiling.

#### Deliverables

- `sliceBudget` partitions case values and assigns proportional floor-divided slices to divisible cases
  while assigning the full budget to each indivisible case. It does not schedule those cases, call
  `fitsBudget`, inspect the actual concurrent workload, or participate in `runSuiteSelection`.

#### Validation

- Unit tests assert divisible slices sum within budget and an indivisible case receives the full budget.
  They do not prove runtime concurrency or applied-resource enforcement.

#### Remaining Work

None for the historical helper landing. Sprint 10.10 removes the definition-only API unless the
identity-bound plan work introduces a real consumer; Sprints 9.10/10.9 own the applied workload
proof and harness scheduling authority.

### Sprint 10.4: Historical four-run-model taxonomy and selector [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/run_models.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Historically name the minimal run-model set and prototype a selection key.

#### Deliverables

- Historical delivered shape: four models — `OneShot` (build-if-needed + `docker run --rm [-it] [mounts]`, budget-capped),
  `HostNative` (host-native build + host invocation), `HostDaemon` (long-running host service), `Cluster`
  (kind+Helm) — and the selection key `(verb x detected-substrate x library-layer x generated-topology)`,
  represented by `selectRunModel`. The L0 prototype delivered the pure, budget-capped
  `oneShotRunArgs` (`docker run --rm [-it] --cpus/--memory [-v mounts] <image> <cmd>`) plus executable
  definitions for `oneShotSeams` and `defaultSeams`. Neither seam was wired to a production or test
  caller; they are definition-only prototypes, not evidence of a live run path, and Sprint 10.10 owns
  their deletion unless a typed-plan consumer appears.

#### Validation

- `HarnessSpec` asserts `selectRunModel` for all four models and that `oneShotRunArgs` is budget-capped,
  mount-bound (`:ro` on read-only), `-it` when interactive, and command-tailed. `run_models.md` documents
  the selection key. `cabal test` passes.

#### Remaining Work

None in the historical taxonomy sprint. Audit later proved the selector has no production consumer and
`Core.dhall` independently declares the same alternatives; Sprint 10.10 removes both parallel surfaces.

### Sprint 10.5: `test` and `check-code` verbs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/engineering/testing.md`, `documents/engineering/code_check_doctrine.md`

#### Objective

This is a historical initial command shape, superseded by Phase 17.4's typed
`test run <case-id>|all` semantics.

Put the `test` and `check-code` verbs on the core tree so every project binary inherits them:
`test` drives `runMatrix`, prints the report card, and exits non-zero when any selected case fails;
`check-code` is the fail-fast image-build gate whose action is supplied through `ProjectSpec`.

#### Command Surface

- `<project> test <case|all>` — drive `runMatrix` over the named case (or the whole matrix with
  `all`), print the report card, and fail the command when the report contains a failed case (the
  project matrix is threaded in via the `TestSuite` hook, Sprint 10.6). **Target surface:** this single
  coupled `test <case|all>` verb is being split into `test init` (writes the sibling `<project>.test.dhall`) and
  `test run <case-id>|all` (target root-only, gated on typed `<project>.test.dhall`), decoupled from deploy
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

The `check-code` verb remains complete. The historical test-shape claims in this sprint are superseded:
Phase 17.4 owns parser/gating, Phase 19.6 owns typed IDs/config, and Phase 10.9 owns execution safety.

### Sprint 10.6: Project test-matrix hook + `all` selector on the inherited `test` verb [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`
(`TestSuite`/`emptySuite`/`allCasesSelector`/`runSuiteSelection`),
`core/hostbootstrap-core/src/HostBootstrap/Command.hs` (`testCommand` parses the selector; its current
help/metavar still misnames that compiled case ID as a `SUITE`, owned by Sprint 17.4),
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs` (`runHostBootstrapCLI` threads the project spec)
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`,
`documents/engineering/derived_project_standards.md`, `README.md`

#### Objective

Make the inherited `test` verb run a project's **own** case matrix, so project tests live under
`test` rather than a per-noun subcommand.

#### Historical Command Surface (superseded)

- At this sprint's closure, `<project> test all` ran the whole supplied matrix and printed the report card.
- At this sprint's closure, `<project> test <case>` ran one case; an unknown id exited non-zero, listing
  the valid ids and `all`.

**Current replacement:** that `test <case|all>` shape became `test run <case-id>|all` under a `test run`
subcommand, paired with a `test init` writer; `all` stays always-a-suite, while root enforcement remains
open and the runner is
`<project>.test.dhall`-gated (development_plan_standards § Z). The `TestSuite`/`runSuiteSelection`/`ProjectSpec`
threading built here is **still valid** and is reused under the new `test run` verb.

#### Deliverables

- The `TestSuite` hook in `HostBootstrap.Harness`: an existential `TestSuite` over the per-project
  `Seams env` plus its `[Case]`, the reserved `allCasesSelector` (`"all"`, always available so a
  project may not name a case `all`), `runSuiteSelection` (selector → chosen cases → `runMatrix`), and
  `emptySuite` for the bare binary's explicit `runBareHostBootstrapCLI` path.
- Historical delivery: `ProjectSpec` carried the non-empty `TestSuite`;
  `coreCommands`/`testCommand`/`runHostBootstrapCLI` threaded it into the inherited verb, and
  `testCommand` parsed a required selector. The current parser retains that selection semantics under
  `test run <case-id>|all`, although its source help and `SUITE` metavar still use the superseded suite
  terminology; Sprint 17.4 owns that exact help/parser repair.
- The bare `hostbootstrap` binary uses `runBareHostBootstrapCLI`; the demo binds `demoSeams`/`demoCases`
  through `demo/app/Main.hs`.

#### Validation

- Historical validation: at this sprint's closure, `cabal build` (core library, bare binary, demo)
  succeeded. `HarnessSpec`
  covered `runSuiteSelection`:
  `all` → whole matrix, a named id → that one case, an unknown id → `Left` listing the valid ids +
  `all`, and `emptySuite all` → `test report: 0/0 passed` through the bare path. `CLISpec` covers
  `ProjectSpec` rejecting an empty project suite, the then-current `test all` exiting non-zero on a seeded
  failed case, and `check-code` running/failing through the supplied action. The then-current CLI surface
  listed a top-level `test`, omitted it below `vm`, and rejected `hostbootstrap-demo test bogus`.

#### Remaining Work

The `TestSuite` existential, `allCasesSelector`/`runSuiteSelection`, `emptySuite`, and the `ProjectSpec`
threading carry over unchanged. The current selection is exposed under `test run <case-id>|all` (a
`test run` subcommand) paired with the `test init` writer and gated on a sibling
`<project>.test.dhall`; it is **not currently root-authority-gated**. `HostBootstrap.Command` still calls
the selector a suite and uses metavar `SUITE`, despite selecting one compiled case ID. Blocked Sprint
17.4 owns the target root-only gate and exact case-ID help/parser contract. The current demo wiring lives
in `demo/src/HostBootstrapDemo/Commands.hs`; the removed historical chain module is recorded in the
legacy ledger.

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

### Sprint 10.9: Exclusive test ownership and failure isolation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot/Native.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/DataRootSpec.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/testing.md`, `legacy-tracking-for-deletion.md`


**Reproduced 2026-07-28 (native Linux GPU run).** Interrupting a harness run leaves both `.test_data` and
a separate `.test_data.hostbootstrap-run-owner` lock directory behind. The next run aborts with
`test data ownership is already active: .test_data`, and because the lock is a bare `createDirectory`
claim with no Open→Closing phase or owner identity, nothing can distinguish a crashed predecessor from a
live one — an operator must remove **both** directories by hand. This is the concrete failure this
sprint's versioned, crash-recoverable reservation replaces.

#### Objective

Make a test run an exclusively owned transaction whose failures are isolated per variant and whose
cleanup cannot delete foreign or concurrently replaced state.

#### Deliverables

- Hold the four § EE ownership clauses before ownership is claimed: a retained bound socket for ports, an
  OS-released lock for host daemons, and provider create-if-absent/CAS plus immutable generation for
  VMs/clusters. For generated config and `.test_data`, bare exclusive create/rename or
  compare-then-unlink binds a pathname and satisfies none of the clauses; a receipt requires the
  OS-released lock, the durable origin record, identity binding, and conditional release together. A
  backend that cannot hold a clause reports `Unsupported` and mints no receipt. See
  [ownership_invariant](../documents/architecture/ownership_invariant.md). **Restated 2026-07-27:** this
  bullet previously required a protected namespace with an identity-bound kernel operation.
- Prove the clauses in this phase's harness suite the same way on every substrate — the ownership tests
  are not `os(windows)`-gated. Cover adversary replacement reported as `Conflict` without clobbering,
  release refused on identity mismatch, a second entry excluded while the lock is held and admitted after
  the holder is killed, and a kill between the origin record and the first write recovered — including
  the **absent-original** case, where the next run restores absence rather than adopting generated
  content.
- Use Phase 9/19's opaque lifecycle-scope/type foundation and define the mode/profile opener here:
  generate the stable run identifier inside a rank-2 opener, acquire its exclusive lease, and expose
  `HarnessAuthority projectId runId` only after that acquisition.
  Fresh Production/Harness profiles require the exact active mode and still-unbound lease. Define a
  separate protected bound-recovery opener for configful abandoned Production `ProjectUp`; it requires
  the exact Phase 15 root, active Production mode, bound lease, verified/bound snapshot and binding, and
  `BoundInvocationRecovery`, and yields only
  `RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration`. It
  cannot mint a fresh profile, Harness authority, or teardown authority.
  Make the precondition verifier derive its total probe from installed project identity, then recheck the
  versioned result inside the same compare-and-swap that acquires
  `ProjectModeLease projectId (HarnessMode runId) brokerGeneration`. Production openers contend on that
  same project-wide mode record; Production retains it across `down`, and Harness releases it only after
  terminal close. Production releases its mode only through a closed
  `ProductionClosureAuthorization`: the settled branch requires the exact `ProjectDestroy` root and
  `DestroySettled`, while any Production verb can use the true-pre-effect branch only with
  `VerifiedNoProjectResourcesAcquired`. The final compare-and-swap revalidates the matching
  mode/lease/snapshot/Open-state tuple and complete Closed-session set, then atomically records
  `ClosedProject`, closes the invocation lease, and releases mode. Session opening compare-and-swaps that
  same project-journal version, so it and finalization have one winner; partial `up`/`down` work cannot be
  relabelled as settled destroy and no mode-cleared partial state exists.
  Acquire each resource-specific reservation under that now-bound identity before its effect, and
  expose to a project `TestComponent` only the harness-indexed planning function. The harness API has no
  route to `Production`, and cluster name/data root/ports derive from the run ID. Validate pure stable
  variant drafts first, then open a fresh generative run/lease for each distinct config variant; cases
  sharing the variant share its stack, and no later variant starts while the prior lease is unresolved.
- Run project-owned assembly only through Phase 19's read-only
  `ConfigAssembly (Harness projectId runId)`, which permits declared config/secret reads but no general
  `IO` or backend mutation. `withAssembledHarnessConfig` consumes the exact run authority,
  scope-correct `ProjectCodec`, and assembled value and jointly yields the root-local verified wire
  identity plus `ValidatedConfig` needed to build the first plan. If assembly, codec validation, or plan
  validation fails before lease binding, the bracket closes the unbound lease only after a protected
  proof that no token, prepared-attempt, journal, or effect exists; a crash leaves an explicit unbound incomplete
  lease for the recovery sweep.
- Record `UnboundRunLease (Harness projectId runId) brokerGeneration` in the protected **root** authority
  broker, persist/verify the stable plan snapshot, and atomically produce
  `BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration` before any `PreparedOperation`.
  Mint a
  one-time `ConfigHandoff` token/grant bound to each accepted edge, exact plan revision, broker generation, child
  config digest, verb, and phase. Immediate parents retain duplex relays to the root; they receive
  no signing/delegation key. The child returns a fresh challenge, verifies the signed grant against an
  independently installed project public key (never one supplied by the envelope), and grant+byte
  verification through the scope-correct project-owned `ProjectCodec` jointly mints generic
  `VerifiedConfigWire (Harness projectId runId) childConfigDigest childConfigId` plus the exact
  `VerifiedHandoff ... ConfigHandoff childConfigId verb phase` and `ValidatedConfig`. Those values do
  not directly authorize a command: `withChildProjectPlan` consumes them with the closed verb and
  non-empty project plan draft, verifies the stable revision, and jointly yields a fresh local
  `ProjectPlan`, `PlanDigestBinding`, and exact
  `ChildPlanAuthority ... planId childConfigId verb phase` inside a rank-2 continuation.
  `authorizeChildProject` consumes that authority; it never receives root/harness-root or signing
  authority. Raw wire cannot be promoted merely because run authority exists.
  Tokens never enter Dhall, `argv`, environment variables, or durable config, and no harness broker can
  sign Production grants.
- Keep the harness root broker live through bring-up, assertion, and recursive teardown. Each child sends
  one one-use command/handoff identity to an atomically opened versioned session after the current broker
  has session admission. Session open and close each advance the shared project-journal version and return
  the sole successor state/permit pair. Registering an operation's initial intent consumes either the
  sole no-prior-generation origin or an exact released-reacquisition `FreshGeneration` origin,
  atomically adds its generation to that exact session, and advances both versions, so no orphan intent
  can be omitted and the caller cannot choose the generation. Clean activation
  mints admission only after proving no older session remains
  Open; abandoned-run activation uses the exact old-permit fence set and verified independent
  complete session/operation manifest. Its protected interpreter rebinds and closes every existing stable session
  record—including a zero-operation Open session—and uses one private total classifier for each persisted
  operation. The closed branches are unknown, the five pre-call continuable phases, already-observed
  retryable, successful, and terminal. Only continuable phases receive current-fence prepare authority;
  only reservation/effect absence, ordinary or adopted same-identity teardown presence, adoption absence,
  repair-original, and managed-phase-from are retryable, and only under the same operation key after old
  permits are fenced; successful and terminal branches receive no effect authority. The interpreter
  settles every operation, verifies the complete required resource-record set, and closes every old
  session before jointly yielding fresh rehydrated resources and current-broker admission. A persisted
  initial intent may have no fence and cannot prepare; recovery idempotently completes the stable
  initial-fence protocol and threads its sole successor state/permit values before exposing the
  continuable branch. Before each
  reservation/mutation/delete, one protected prepare compare-and-swap revalidates exact
  project-mode/broker/authority epochs, bound lease, active revision/no migration freeze, Open-project
  state, verb/phase/frame/session, current fence, journal version/phase, operation key, the exact
  plan-owned closed zero/one/many precondition set, and call digest. It reruns every target/dependency
  probe and conditional version; stale/replaced/not-ready evidence returns no `PreparedOperation`. It records the
  exact unknown state before jointly returning the only matching
  `PreparedOperation`/`PreparedPreconditions` pair the adapter accepts together with the fresh-versioned successor Open-session, Open-project
  operation state, and revision-permit authority; the consumed journal version cannot authorize another
  prepare or close. The prepared pair retains the exact target identity/kind, generation,
  operation/key, precondition set/call digest, session/fence/attempt, and journal version, and must match the plan descriptor,
  operation binding, or teardown step. Every terminal observation returns `OperationAdvance` on success
  or typed failure; its eliminator yields the result only with the sole successor Open-project
  state/revision-permit pair; retained `Ready`/prerequisite values and either half of the pair are not
  effect authority. Initial fence creation and crash-time
  `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved` rotation are durable and resume the same
  proposed epoch; a delayed old permit is rejected or deduplicated. A terminal acknowledgment first
  verifies every registered outcome settled and compare-and-swaps the exact session version Closed, so a
  concurrent prepare or retained proof cannot win. **Do not**
  serialize generative handles/journals/receipts or consumed tokens. A child or recovered invocation
  reprobes stable records and mints fresh local values under its own `planId`/`configId`. Mint a fresh
  edge token for every later edge, including teardown; each external effect separately requires its
  exact version/phase/precondition-set/call-digest/session/fence/attempt/journal-indexed
  `PreparedOperation`/`PreparedPreconditions` pair. Lost outcome/ack resumes through the journal rather
  than blind replay. Delete only exact owned identities and retain ownership while quarantining changed
  config bytes.
- Add the ordinary Production invocation-close transaction, distinct from terminal project/mode
  release. Phase 16's successful recursive `ProjectUp`/`ProjectDown` interpreter may mint
  `ProductionInvocationCompleted` only after the protected complete session/operation sets are terminal,
  no prepared operation is live, and broker session admission is revoked at the exact journal version. One Phase 10
  compare-and-swap revalidates that proof, Production mode, bound lease, snapshot/binding, active
  revision, complete resource records, and `OpenProject`, then closes only the
  `BoundRunLease`/broker invocation. The closed branch preserves and returns the exact Production mode
  lease, snapshot/binding, active revision/journal, rehydrated resources, and successor Open state, but
  no bound lease, admission, or revision-permit authority. An uncertain acknowledgment returns only
  `ProductionInvocationCloseUnknown`; bound recovery classifies the durable terminal record separately
  and may only reprobe or resume its stable idempotent close key. It cannot reopen work, release mode,
  mark the project Closed, or release resources. `releaseProductionMode` remains exclusive to settled
  destroy or the true-pre-effect refusal.
- Before allocating any new harness run, `recoverAbandonedHarnessRuns` enumerates protected incomplete
  unbound and bound leases at one store version. Separate rank-2 fold callbacks receive each exact
  existential `VerifiedIncompleteRunLease`, and the sweep rechecks terminal closure after every
  callback; callers cannot manufacture/skip an old run or return no-op success. An unbound member closes
  only after the sole
  `verifyUnboundLeaseHasNoEffects` verifier produces exact-version
  `VerifiedUnboundLeaseHasNoEffects`; a stray effect-shaped record refuses. Each bound
  `Harness projectId oldRunId` reopens through
  `withAbandonedHarnessRun`. That rank-2 opener jointly yields only the exact old bound snapshot,
  plan-digest binding, `BoundInvocationRecovery`, already-bound lease, `ProjectDestroy`, and narrow
  recovery/close authority under a fresh broker generation—never a rebound generic journal, general
  harness, or `ProjectUp` authority. Its exhaustive first branch is Open revision recovery versus the
  exact persisted Closing epoch; Open then dispatches normal/incomplete/completed revision recovery before
  any journal exists. A normal revision with an older Open operation session must run the protected
  recorded-session interpreter; missing/duplicate members, wrong session/operation membership, or an
  unresolved internal recovery step cannot yield current-broker admission. Its total operation
  discriminator reprobes unknown operations, retries only the closed fenced same-key whitelist, and
  resumes the five continuable phases only through current-fence prepare, then settles successful/
  terminal observations without reminting effect authority. Normal and completed-
  migration activation both verify the complete rehydrated resource set and prior-session settlement
  before yielding the new revision's `CurrentBrokerSessionAdmission`; the committed-new activation window
  cannot open a session. Recovery then finishes child-first teardown. At a child boundary with
  edited/missing old config, require the signed snapshot-derived `VerifiedRecoveryWire`, exact
  `RecoveryProjectionBinding`, and
  `VerifiedHandoff ... RecoveryHandoff recoveryWireId verb TeardownPhase` plus the closed
  forest-produced `TeardownAuthorizationPoint`. Its private branch contains either the ordinary
  child-settled/cursor pair or destroy-only pre-descent step. Only the bound snapshot, matching plan
  binding, complete `RehydratedResourceSet`, and that exact point/step can jointly mint the recovered
  frame and a closed owned-or-released evidence sum. The owned branch yields its managed phase handle,
  receipt, and bindings; the released branch yields only its verified tombstone/bindings, has no backend
  call authority, and needs protected absence plus a distinct acquisition key for `FreshGeneration`.
  That token is eligibility only: its sole consumer constructs the exact reacquisition origin, and
  registration revalidates/consumes the protected version atomically with the new generation/session
  membership. Missing, foreign, or replaced records yield no such evidence. Recovery cannot mint a normal
  config or `ProjectUp`. Unknown snapshot/foreign replacement
  yields operator resolution and blocks a fresh run. Only after every old lease closes does a protected
  empty-set compare-and-swap mint
  `ClosedAbandonedHarnessRuns projectId recoverySweepVersion`; `withHarnessRoot` consumes that exact
  versioned proof atomically while allocating the new run. Choosing another ID or racing the sweep
  cannot bypass unresolved ownership.
- Keep `.test_data/<runId>` inside the single plan with `Preserve` for ordinary `project down` and
  `project destroy`, so destroy→up durability assertions can run within one variant. After assertions and
  either an exact settled destroy or a verified true pre-effect refusal, derive closure only through the
  sole producers. `verifyDestroySettled` checks the complete plan-derived forest, terminal release
  observations, protected journal, lack of unresolved nodes/live prepared operations, and the independently complete
  Closed session set;
  `verifyNoProjectResourcesAcquired` checks the exact bound tuple has no
  resource operation/prepare/fence/receipt/effect record and every registered session is Closed and
  empty. Only their closed conversions mint `ProjectClosureEvidence`; unresolved partial ownership
  yields neither.
  Combine that proof, project-wide Harness mode lease, bound snapshot/lease, exact versioned Open state,
  and `HarnessCloseRoot`—derived from the live root or abandoned-run recovery authority.
  `authorizeHarnessClose` verifies ordinary sessions Closed and atomically CASes Open→a fresh Closing
  epoch while creating the close journal; a concurrent prepare and close cannot both win. Its
  plan-derived terminal projection releases the exact owned generated config/data-root generations
  through close-specific durable unknown/reprobe/fence permits. A persisted Closing epoch resumes only
  that close journal. Every terminal close observation returns `HarnessCloseAdvance` on success or typed
  failure; its eliminator yields the only successor close journal. After all close outcomes/sessions
  settle, one finalizer atomically records `ClosedProject`, closes the bound lease, and releases the exact
  Harness mode epoch last. Production and another run have no constructor for that authority.
- Represent acquisition `Conflict`, `SafetyRefusal`, `Unsupported`, lifecycle `Failure`, assertion failure, and teardown
  failure as distinct structured report-card outcomes while continuing independent variants when safe;
  `ManagedResult Unchanged` retains the managed handle and teardown receipt, while `ForeignResult` exposes
  only an `Unmanaged` handle that cannot type-check at teardown. Explicit adoption requires matching
  opaque authority and reports `Changed Adopted`.
- Consume Phase 19's typed case IDs/config variants; this phase owns engine isolation and reporting, not
  the project-defined config schema or demo variant generation.

#### Validation

- Deterministic concurrency tests race two harnesses and external non-cooperating actors against every
  supported reservation backend and prove exactly one authoritative acquisition, or an explicit
  `Unsupported` outcome where the platform cannot provide it.
- Compile-time fixtures prove a project `TestComponent` cannot call the Production planner.
- Cross-process tests prove one valid broker challenge/grant works once and reject replay/recorded
  transcripts, stale broker generation, wrong project/plan/frame/scope/config identity/hash, raw-wire
  promotion, a public key supplied by the untrusted envelope, broker loss, truncated envelopes,
  bring-up-token reuse during teardown, and token transport through Dhall, `argv`, or the environment.
  Nested-edge tests prove children relay to the root rather than signing. Prepare/prepared-operation tests prove the
  exact command epoch/verb/phase/Open session/current fence, closed precondition set/fresh prepared
  preconditions, and durable unknown state predate every
  effect; one invocation cannot open two sessions, broker loss before prepare refuses, and loss after a
  prepared backend call reprobes. Kill/race tests cover initial fence, all rotation phases, delayed old prepared operations, session
  open/prepare/outcome/settle/close, and prove prepare versus session/project close has one winner.
  Compile/runtime fixtures reject either half of the prepared pair, retained `Ready`, wrong
  edge/precondition-set/call digest/version, or a pair for another target/operation/teardown step and prove
  every success or typed failure exposes its result only through `OperationAdvance` with the sole
  successor state/permit pair. Kill after each continuable pre-call phase and each persisted retryable
  observation proves recovery can re-enter only its matching current-fence or fenced same-key branch;
  successful and terminal branches cannot obtain effect authority, and a kill cannot split initial intent
  registration from session membership. After a hard kill immediately after that atomic write but before
  the first fence record, recovery starts and persists the sole initial-fence epoch; an interruption after
  that record resumes the persisted epoch. Neither boundary can prepare early.
  Nested recovery with a
  missing old config proves only the recovery-kind handoff works; swapping a config-kind and
  recovery-kind grant is a compile-time/API failure. Missing, duplicate, foreign, or replaced
  rehydration records cannot produce a recovered frame or owned/released evidence. The owned branch alone
  carries a managed handle/receipt, while the released branch alone carries a verified tombstone and
  requires protected absence for fresh-generation rollover. First acquisition without no-history
  evidence and reacquisition with a stale/reused/wrong-resource origin fail their registration
  compare-and-swap. Completed migration cannot open a session
  before activation, and activation yields
  current-broker admission only after prior sessions settle.
- Hard-kill/failure injection at every lifecycle stage proves the next invocation reopens the exact old
  run, owned partial state is cleaned, foreign state is retained, teardown failure turns the variant red,
  and a later variant runs only after the old lease closes. Kill points cover Open→Closing, both sides of
  every generated-config/data-root close effect, success/failure `HarnessCloseAdvance`, close settlement,
  lease closure, and mode release; persisted Closing cannot remint Open. Closure tests prove incomplete
  forests, live prepared operations, resource/effect-shaped records, Open sessions, and non-empty sessions fail the
  sole destroy/no-effect verifiers; a Closed empty session remains a valid pre-effect refusal.
  Destroy→up in one still-open run reads the same bytes, while terminal close records `ClosedProject`
  and removes only that run's exact generations.
- Deterministic cross-profile races prove the precondition observation is rechecked while acquiring the
  shared mode lease, Production and Harness never overlap, Production `down` retains exclusion, and
  Harness releases its exact mode epoch only after close. Production closure fixtures prove settled
  release requires the `ProjectDestroy` constructor, while an `up`/`down` pre-effect refusal can release
  only through the exact true-no-effect constructor; partial work inhabits neither. A session-open/
  finalizer race has one winner, and kill/restart observes either the complete Open tuple or the atomic
  `ClosedProject`/closed-lease/released-mode tuple.
- Production invocation-close races prove a successful ordinary `up`/`down` closes its bound lease and
  broker admission without clearing Production mode or changing the active snapshot, Open-project
  state, or resource records. Open/nonterminal/missing sessions, live prepared operations, and stale journal versions
  cannot mint the completion proof. Kill/lost-ack recovery resumes the same close key and cannot obtain
  operation authority or route through `releaseProductionMode`.
- The real `test run all` gate proves no production profile/name is used and leaves no owned resources.

#### Remaining Work

**Reproduced 2026-08-03 on Apple Silicon — the interrupted-run recovery defect is only half fixed, and
the two halves mask each other.** A harness run was killed mid-variant (a `SIGKILL` to the run's process
tree, which is what a crashed run, a lost session, or a power failure looks like). Both halves below were
then observed in sequence on a real host; neither is a static-test finding.

1. **The generated config is still owned by a bare lock directory, and its existence check pre-empts the
   sweep that would resolve it.** This is the deliverable above that begins *"For generated config and
   `.test_data`, bare exclusive create/rename or compare-then-unlink binds a pathname and satisfies none
   of the clauses"* — `.test_data` was carried across on 2026-07-29 and the generated config was not.
   `Config.Schema` still claims it with a `<config>.hostbootstrap-test-owner` **directory** beside the
   file, holding the payload for byte-comparison at release: a pathname claim with no protected durable
   origin record, no stable kernel-identity binding, and no OS-released lock — none of the four § EE
   clauses, and structurally the same design the `.test_data.hostbootstrap-run-owner` directory was
   removed for.

   The ordering makes it unrecoverable rather than merely weak. `Command.runTestRun` refuses on a bare
   `doesFileExist cfgPath` — *"a production config already exists at …; refusing to overwrite it"* —
   **before** `withCanonicalProjectRoot`/`withHarnessRoot` reaches `recoverAbandonedHarnessRuns`, and
   without consulting the sidecar that marks the file as harness-made. So after the common failure mode
   the sweep never runs at all. The refusal exists in three places — `Command.hs`, `Harness.hs`
   (`testSafetyPreconditions`), and `Lifecycle/Mode.hs` — and only the third derives its subject from
   installed project identity, so the fix reconciles them rather than patching the first.

   The shape of the repair is already built: `Harness.DataRoot` holds all four clauses for a directory
   over an injected identity backend, and the generated config is the same protocol over a file.
2. **A bound abandoned run has no operator recovery path at all.** With the config removed by hand, the
   sweep did run, correctly classified the leftover run as bound, and refused the whole matrix
   (`10/10 REFUSED`, *"the abandoned run run-… must be recovered before a new run starts"*). That refusal
   is right — it is fail-closed and it names the run — but nothing can act on it: bound-lease recovery
   *reports* rather than resolves, which this sprint already states, and `withAbandonedHarnessRun` has no
   caller. The only way forward was to delete four protected records
   (`lease.…`, `dataroot.…`, `snapshot.…`, and the project-wide `mode.…`) plus the run's empty
   `.test_data/<runId>` by hand — exactly the hand-cleanup the sprint's reproduction section says it
   exists to eliminate, moved from the lock directory to the protected store.

The second is a restatement of this sprint's own open bound-recovery item with a live reproduction
attached. The first is new, and it is the more damaging of the two: while it stands, the abandoned-run
sweep cannot run at all after the common failure mode, so the recovery machinery that *is* built is
unreachable in exactly the case it was built for.

**Delivered 2026-07-29 — project-wide mode, run leases, the fresh profile openers, and the recoverable
run reservation that replaces the lock directory.**

- `HostBootstrap.Lifecycle.Mode` owns the project-wide exclusion. Production and Harness contend on one
  protected mode record: Production takes it and **retains** it across a second entry (which is what
  makes `down` keep the exclusion), a harness run may take it only when it is absent, and a harness run
  against live Production is `ModeHeldByAnother` rather than an overlap. Harness mode is released only
  after the run's lease closes, and the lease is always closed before the mode, so a crash between them
  leaves the mode held and the run recoverable rather than the mode cleared with work outstanding.
- The **run lease** is durable and classifiable. `withHarnessRoot`/`withProductionRoot` record an
  `UnboundRunLease` before any plan exists; `bindRunLease` compare-and-swaps it into a
  `BoundRunLease` naming the exact spec and plan digests, and refuses a second bind. Both composite
  brackets run the Phase 15 verifier *inside* the protected mode transaction and then release the entry
  before the continuation, so the transaction is atomic without holding a lock across a 30-minute run.
- The **fresh Production and Harness `LifecycleProfile` openers** require the exact active mode lease
  and the still-unbound run lease. `withProductionLifecycleProfile` does not typecheck against a
  harness lease (`HarnessLeaseAsProduction.hs`), so a test component has no route to Production.
- The **harness safety precondition verifier derives its sibling-config half from installed project
  identity** and is re-run inside the same protected entry that takes the mode, so nothing can slip
  between the check and ownership.
- `recoverAbandonedHarnessRuns` enumerates every incomplete lease, closes each unbound one behind the
  protected `verifyUnboundLeaseHasNoEffects` proof (a single effect-shaped record refuses), releases
  that run's mode, hands each bound one to the caller's fold, and then **rechecks**: a fold that
  resolved nothing cannot report a vacuous success, and `withHarnessRoot` re-verifies emptiness inside
  its own entry so racing the sweep cannot bypass unresolved ownership.
- Production mode release runs only through `releaseProductionMode`, which requires the
  `ProductionCloseRoot` and the closure evidence to agree: a settled-destroy root paired with
  pre-effect evidence is `ModeClosureMismatch`.
- **The reproduced defect is fixed.** `HostBootstrap.Harness.Ownership` is the production run-ownership
  bracket the command layer now installs: it sweeps abandoned runs, takes mode and lease, records the
  durable origin of `.test_data` (the exact present/absent observation) *before* creating it, and on
  exit closes the lease, releases the mode, and removes the directory only when the recorded origin says
  this run created it. The bare `createDirectory` claim and its
  `.test_data.hostbootstrap-run-owner` directory are gone, and `HarnessSpec` proves a run killed
  mid-body does not block the next run.
- The engine takes ownership through an injected `HarnessRunOwnership` seam, so `runSuiteSelection`
  keeps owning only selection, isolation, and reporting (§ W).

**Delivered 2026-08-01 — per-variant ownership and exact run identity at config assembly.**

- `runSuiteSelection` now opens and resolves `HarnessRunOwnership` separately for every distinct
  `ConfigVariant`. Cases sharing a variant still share one stack, but variant N+1 cannot acquire until
  variant N's ownership bracket returns. An acquisition refusal is recorded against only that variant,
  and the matrix proceeds after the refusal without running its lifecycle.
- The ownership bracket now supplies the stable textual identity of the generative run it actually
  acquired. `ConfigVariant` threads that identity into the generated-config bracket, and `Command`
  derives `HarnessAuthority` from it instead of from the reusable `VariantId` label.
- The live command path now runs project assembly through `withAssembledHarnessConfig`, jointly checking
  the scope-correct codec/wire identity and yielding `ValidatedConfig` before the exclusive generated
  config is installed. It no longer calls `runConfigAssembly` directly.
- `HarnessSpec` pins the full acquire → exact-run config → up/assert/down → release ordering for two
  distinct run identities and proves one ownership refusal does not suppress a later variant.

Focused validation (2026-08-01): `cabal test hostbootstrap-core-test --test-options="-p HarnessSpec"
--ghc-options=-Werror` passes all **23** cases on Windows. This is the first live per-variant seam, not
Sprint 10.9 closure: the authority opener remains independently callable, and bound profile/plan,
terminal-close, recovery, authenticated handoff, reconciler producers, and the full race matrix remain.

**Validated 2026-08-01 — the four previously unregistered authority fixtures now run.**
`CompileFailSpec` registers `ForgeHarnessAuthority.hs`, `HarnessConfigAsProduction.hs`,
`CrossRunPlaintext.hs`, and `ProductionPlaintext.hs`, and checks each fixture's intended diagnostic so an
unrelated compiler failure cannot satisfy the gate. `ClosingPermitAsOpen.hs` subsequently joined the
same registry and pins the Open/Closing permit boundary. The focused public-boundary group passes
**39/39** with `-Werror`; Fourmolu, `git diff --check`, and the LF check pass for the changed registry.

**Delivered 2026-08-01 — ownership finalizer failures are no longer discarded.**

- A completed ownership bracket returns its body result together with a typed optional close failure:
  `HarnessDataRootCleanupFailed` or `HarnessModeCloseFailed`. The production bracket uses
  `generalBracket`, so synchronous and asynchronous exits still run finalization, and it propagates
  data-root release, protected-entry, no-effects proof, and lease/mode-close failures.
- A cleanup failure preserves the variant's assertion rows and appends a labeled `TeardownFailed` row.
  Because the prior lease is unresolved, every later unstarted variant is refused without entering its
  ownership/config/lifecycle bracket. An ordinary acquisition refusal remains isolated and permits a
  later variant to acquire.
- Native identity-replacement coverage proves a replaced data-root generation is retained, its lease is
  not falsely closed, and the failure reaches the report. A real `ThreadKilled` case proves the
  asynchronous bracket releases cleanly and admits a successor.

**Delivered 2026-08-01 — project journal phase permits are type-distinct.** `ProjectPermit` is Open-only;
`beginClosingProject` consumes it and returns `ClosingProjectPermit`, and only that type can enter
`recordClosedProject`, which returns `ClosedProjectPermit`. Session/operation mutations now revalidate
the exact Open state and project version before touching their secondary record. The stale-prepare test
then uses the live successor to perform attempt 1, proving the rejected stale call did not first rewrite
`IntentRecorded`; the former nominal "closed" test now performs a real Open → Closing → Closed
transition and proves prepare is refused. This closes the reopen/type-confusion and stale-prepare
pre-mutation defects, but the remaining multi-record transitions still require one crash-consistent
aggregate transaction before Sprint 10.9 can close.

Integrated validation (2026-08-01): the complete Windows core suite passes **792/792** with
`cabal test hostbootstrap-core-test --ghc-options=-Werror`. `HarnessSpec` contributes **27** cases,
`SessionSpec` **30**, and `AuthoritySpec` **54**; the public compile-fail boundary contributes **39**.

**Delivered 2026-08-01 — one exact owned root and an immutable live plan binding.**

- `HarnessRunOwnership` and `ConfigVariant` carry the exact authority acquired for that generative run.
  The public arbitrary-text harness-authority opener is gone; `HarnessRoot` retains the internally minted
  authority, and `OwnedHarnessRoot` retains that exact authority together with the exact protected store,
  installed project, and canonical root. Production derives its authority directory from that same
  installed-project/root pair. Compile-fail coverage rejects opening harness authority from text.
- The CLI planner is scope-polymorphic through the live harness path. After the scope-correct profile is
  opened, the command builds the plan once, persists revision 1, verifies the persisted snapshot, and
  binds the lease before generated config or suite effects. Only `FreshRunLeaseBinding` proceeds;
  an existing binding is recovery-required rather than silently reused.
- Snapshot persistence is immutable. Byte-identical persistence is an idempotent no-op that does not
  advance the protected record version, while any revision/spec/plan substitution is refused and leaves
  the original record unchanged. Focused tests also prove a Production/Harness mode mismatch cannot reach
  the planner or snapshot and that the live CLI body observes its matching bound snapshot.

**Delivered 2026-08-01 — crash-consistent project/session journal transactions.**

- `HostBootstrap.Lifecycle.Transaction` coordinates every Session-owned multi-record transition with a
  durable redo descriptor: `Idle` or `Applying`, a stable sequence, and exact stamped target records.
  Recovery deterministically completes an `Applying` transaction before any Session authority read.
- Project/session opening, atomic initial-intent plus exact session membership, prepare, outcome
  acknowledgement, session close, Open→Closing, and Closing→Closed now commit through that coordinator.
  The project permit is the coordinator's sole successor permit, and exact recorded membership replaces
  prefix discovery for current-format sessions (the prefix scan remains only for legacy records).
- Failure injection after `Applying`, after every target boundary, and immediately before commit proves
  restart convergence for every Session-owned transaction kind. The split intent/membership boundary,
  stale-permit behavior, a stray prefix-shaped record, and prepare versus session/project close races are
  covered. A compile-fail fixture rejects construction of the private interruption exception; merely
  installing the scoped test failpoint changes no durable record.

Integrated validation (2026-08-01): a clean external-build-directory gate passes the complete Windows
core suite at **826/826** under `-Werror`; the demo workspace passes **110/110** plus the embedded
**826/826** core suite under the same gate. `SessionSpec` contributes **57** cases and the public
compile-fail boundary contributes **40**.

Validation (2026-07-29): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **619**; the demo workspace passes **106** demo tests plus
the embedded **619**-test core suite. `AuthoritySpec` contributes **26** cases run against a real
filesystem and a real kernel lock, including the mode-exclusion, lease-bind, closure-mismatch, and
abandoned-run cases above, plus cross-process exclusion proved with the production primitive.

**Delivered 2026-07-29 — the four § EE clauses for the data root itself.**

`HostBootstrap.Harness.DataRoot` is the data root's ownership backend, and it is the **first § EE
backend wired into a production route**: `Harness.Ownership` — the bracket every `test run` executes
inside — now acquires and releases `.test_data` through it.

- **clause 1** is structural. Every entry point demands the caller's `ProtectedSession`, and the whole
  observe → record-origin → create → bind-identity sequence runs inside one `withProtectedEntry`. This
  also fixes a real gap in the 2026-07-29 bracket, where the `createDirectory` ran *after* the protected
  entry had already been released.
- **clause 2** publishes the durable origin record before the directory exists, and it names the exact
  prior state: `origin absent`, or `origin present <identity>` for a directory an operator left behind.
- **clause 3** binds ownership to the created directory's own stable kernel identity, read by
  `Harness.DataRoot.Native` — POSIX `lstat` `(device, inode)`, and on Windows
  `GetFileInformationByHandle` over a handle opened with `FILE_FLAG_BACKUP_SEMANTICS` (required for a
  directory) and `FILE_FLAG_OPEN_REPARSE_POINT`. The removal decision no longer rests on the recorded
  origin boolean.
- **clause 4** re-observes that identity under the same entry and removes the directory only on an exact
  match. A same-named replacement, or a path that is now absent, is a structured `Conflict`: nothing is
  removed, the record is retained for the next run's recovery, and a stranger's directory is never
  deleted. The pure § Z `selfCreatedTestDataRemoval` guard still decides *policy* (a found directory is
  never in the removal set) with the identity match deciding *authority*.
- A backend that cannot report a stable identity is `Unsupported` and mints no ownership at all; the
  directory is not created.
- **Recovery** treats the record as the authority. An abandoned run whose origin says *absent* has its
  generated content removed rather than adopted — including the crash window between publishing the
  origin and binding the identity, where no managed identity was ever recorded. A recorded pre-existing
  directory is preserved whatever it looks like now. `recoverAbandonedHarnessRuns` grew a **second fold
  callback** so an unbound run's owned state is reclaimed *before* its lease is closed, while the run is
  still identifiable.

**Delivered 2026-07-29 — structured report-card outcomes.**

`CaseResult` no longer flattens every non-passing outcome into one `Fail String` with a parseable
prefix. `Fail` is now exactly the project's own assertion verdict; the engine's classifications are
distinct constructors it alone produces, so a project assertion cannot label itself a refusal or a
teardown failure:

- `Refused` — a post-ensure safety probe found pre-existing operator state. Teardown deliberately does
  **not** run, because a refusal proven to precede acquisition has an empty rollback set (§ Y);
- `LifecycleFailed` — an attempted lifecycle operation broke (bring-up, a case setup, or a throwing case
  body), carrying the cause through `displayException` rather than a bare exit code (§ CC);
- `TeardownFailed` — cleanup broke. This is now an **appended row** rather than an overwrite: the
  per-case results are preserved and the variant still goes red with the cause named, so "the assertions
  passed but the stack did not come down" is legible instead of being flattened into one reason per case.

`caseResultPassed`, `caseResultLabel`, and `caseResultReason` are total over the outcome set, so a new
outcome cannot be silently counted as success, and the report card prints a distinct label per outcome
(`PASS`/`FAIL`/`REFUSED`/`BROKEN`/`LEAKED?`). The `Conflict` and `Unsupported` rows this bullet also
names are **not** added yet: nothing produces them until the reconcilers are wired at their call sites
(Sprints 5.7/16.6), and adding unproducible constructors would be exactly the definition-only surface
§ T forbids.

Validation (2026-07-29): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **729**; the demo workspace passes **106** demo tests plus
the embedded **729**-test core suite under `-Werror`. `HarnessSpec` proves each outcome separately: a
throwing case body and a throwing case setup are `LifecycleFailed` rather than assertion failures, a
failed bring-up is `LifecycleFailed` and still tears down, a `SafetyRefusal` is `Refused` with teardown
call count `0`, a failed teardown leaves the passing case row intact and adds a `TeardownFailed` row that
makes `allPassed` false, and one rendering case asserts all five distinct labels and the pass count.

The earlier data-root validation, re-run after this change: the new `DataRootSpec` contributes **18**
cases, all of them driving the
production driver and the production native identity backend against a real filesystem and a real
kernel — deliberately **not** `os(windows)`-gated, so every substrate the suite runs on proves the same
clauses. They cover: origin-before-creation for both the absent and the pre-existing case, an unsettled
same-key record refused rather than overwritten, the record codec and its malformed-input refusal, the
bound identity equalling the created directory's own, a same-named replacement reading as a different
object, `Unsupported` minting no ownership and creating nothing, removal of a self-created root,
preservation of a found root's content, refusal to release a replaced or vanished root with the
replacement left intact, a receipt refused against another run's record, and the four recovery branches
(pre-binding crash, post-binding crash, foreign replacement refused, and a recorded pre-existing
directory preserved).

**Delivered 2026-07-29 — the per-run `.test_data/<runId>` generation.**

A run no longer owns the shared `.test_data` path. `HostBootstrap.Harness.testDataGeneration` derives
`.test_data/<runId>` from the run's generative identity, and `Harness.Ownership` acquires, releases, and
reclaims *that* directory. The shared parent is explicitly scaffolding: it is created if missing, is never
bound to a receipt, and is never removed. Two consequences matter and are both asserted:

- two runs can never contend for the same durable object, because the generation is named by a generative
  `runId` — so § Z's "each distinct config variant receives a fresh harness `runId`, cluster/data root, and
  exact plan/config lease" is now true of the data root and not only of the lease;
- the abandoned-run sweep reclaims the *predecessor's* generation by name as well as by kernel identity,
  because `reclaimUnboundRun` derives the same `.test_data/<oldRunId>` path from the lease it is settling.

`HarnessSpec` grew four cases: exactly one generation exists while the run holds it (observed from inside
the bracket); an exception releases the generation and leaves the parent present and empty; a run killed
mid-body leaves no orphan generation after the next run's sweep; and consecutive runs own directories with
different names.

**Delivered 2026-07-29 — plan snapshots, the classified lease binding, and bound-Production recovery.**

`bindRunLease` no longer accepts caller-supplied digest strings, and an already-bound lease is no longer an
error:

- **Plan snapshots are persisted and verified.** `persistPlanSnapshot` writes one run's non-secret
  revision/spec/plan record; `verifyPlanSnapshot` reads it back and binds its two digest indices inside a
  rank-2 continuation, yielding the opaque `VerifiedPlanSnapshot projectId specDigest planDigest`.
  `bindRunLease` consumes *that*, so "the lease is bound to a snapshot that was persisted and verified"
  is structural rather than a comment (§ EE). A run with no persisted snapshot is `ModeSnapshotMissing`,
  not a default.
- **Binding classifies its own outcome.** A still-unbound lease yields
  `FreshRunLeaseBinding` carrying the `BoundRunLease` plus `NormalActiveRecovery` — the opaque proof that
  no recovery is owed. An already-bound lease is the abandoned-invocation case and yields
  `ExistingRunLeaseBinding` carrying the same `BoundRunLease` plus `BoundInvocationRecovery`, so a caller
  cannot mistake a resumed invocation for a fresh one. A lease bound to *different* digests is
  `ModeSnapshotMismatch`: that is a snapshot substitution, not a resumption.
- **The two recovery eliminators are scope-exclusive.** `eliminateProductionBoundRecovery` distinguishes an
  exact terminal `up`/`down` acknowledgment — which yields only the stable `InvocationCloseKey`, because
  resuming that same close is the sole legal continuation — from Open operational revision recovery.
  `eliminateHarnessBoundRecovery` distinguishes an exact persisted Closing epoch from Open. Each **refuses
  the other's disposition** with `ModeWrongRecoveryScope`, so a Production invocation cannot consume a
  Harness Closing epoch and a Harness run cannot consume a Production acknowledgment.
- **The Open branch reports which side of the migration barrier it is on.** `OpenRevisionKind` is
  `NormalRevision | IncompleteMigration key | CompletedMigration key`, read from a durable record written
  by `recordOpenRevisionMigration` — so a restart resumes the correct side rather than inferring it from
  the current config.
- **`RecoveredProductionLifecycleProfile` is a distinct type from `LifecycleProfile`,** indexed by the
  exact spec/plan digests and the local `planId` its rebuild is fixed to. There is no function from it to a
  fresh profile, to Harness scope, or to teardown authority.
  `withRecoveredProductionLifecycleProfile` requires the exact Production `VerbUp` root, the currently held
  Production mode under the same broker generation, the bound lease, the verified snapshot, and the **Open**
  revision branch. Passing a terminal acknowledgment cannot reach it, so an invocation that already
  finished cannot have a plan quietly rebuilt for it.

`AuthoritySpec` grew seven cases covering each of those refusals and both eliminators, run against the real
protected store.

Validation (2026-07-29): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **737**; the demo workspace passes **106** demo tests plus the
embedded **737**-test core suite under the same gate. `DocValidatorSpec` passes.

**Delivered 2026-07-30 — the two close transactions and the `ClosingProject` journal state.**

- **`ClosingProject epoch` is now a journal state**, between Open and Closed.
  `beginClosingProject` compare-and-swaps Open → Closing against the caller's exact permit, and session
  opening advances that **same** record version, so a close and a concurrent session-open contend on one
  version and exactly one wins. Resuming the *same* persisted epoch is idempotent; a *different* one is a
  second close and is refused. `recordClosedProject` accepts only the exact epoch that authorized it, so an
  Open journal cannot jump straight to Closed, and the prepare compare-and-swap gained an explicit Closing
  branch — which is what stops a prepare racing an authorized close.
- **`verifyAllSessionsClosed` is the completeness proof.** It enumerates the complete session set for a
  plan at one store version and refuses while any member is Open — including a **zero-operation** Open
  session, which is exactly what an invocation killed right after opening leaves behind. It is bound to the
  plan digest it covered, not only to phantom indices, and both consumers compare that digest against the
  bound lease's; a proof taken over another plan's journal is `ModeSnapshotMismatch`.
- **The Production invocation close** is distinct from project closure.
  `completeProductionInvocation` mints `ProductionInvocationCompleted` from the bound lease plus that
  proof, and `closeCompletedProductionInvocation` records the terminal acknowledgment under a stable
  `InvocationCloseKey` **before** closing the lease — so an interruption between the two leaves evidence
  bound recovery classifies as `ProductionTerminalAcknowledgment` and resumes the same key, rather than an
  ambiguous half-closed lease. An uncertain acknowledgment is its own
  `ProductionInvocationCloseUnknown` constructor, not an error. It does **not** release the mode, mark the
  project closed, or release any resource: the test asserts a harness run is *still* refused afterwards,
  which is what makes `down` retain the exclusion.
- **The harness terminal close.** `authorizeHarnessClose` requires the exact Harness mode lease for that
  run, the bound lease, and the completeness proof, then persists the Closing epoch so a crash resumes
  this close (bound recovery reaches `HarnessPersistedClosing`). `finalizeHarnessClose` closes the lease
  and releases the Harness mode **last**, so a crash between them leaves the mode held and the run
  recoverable; the test proves the next run may then start.
- This also gives `recordProductionInvocationAcknowledgment` and `recordHarnessClosingEpoch` their
  production consumers, so neither remains a definition-only surface (§ T).

`AuthoritySpec` grew **five** cases against the real protected store, covering each refusal above.
Validation (2026-07-30): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **743**; the demo workspace passes **106** demo tests plus the
embedded **743**-test core suite.

**Delivered 2026-07-30 — the deterministic concurrency race, and the ownership defect it found.**

The § Z validation clause "race two harnesses … and prove exactly one authoritative acquisition" was
written as a real cross-process race: four processes, started together, each attempting the whole
production reservation (sweep → mode+lease → data root) against one state root, with the winner
**holding** the run so every competitor overlaps it rather than queueing behind it.

**It failed on the first run: two processes both acquired.** The cause is structural, not a race window.
`recoverAbandonedHarnessRuns` classifies any incomplete lease as abandoned, and **liveness was never
established** — so a starting run swept the *live* winner's lease, `releaseModeIfRun` released the
winner's project-wide mode, and it then took ownership. Two harness runs simultaneously believed they
owned the project, which is exactly the exclusion § Z exists to provide. Nothing before this could have
caught it: every prior ownership test is sequential, where the predecessor really is dead, and the
sequential tests pass either way.

The fix is the § EE clause-1 primitive applied to the **run** rather than to a single transaction. The
protected store's entry is taken and released per transaction, so it can never answer "is the run that
owns this project still alive?" — and without that answer the sweep cannot tell a dead predecessor from a
live peer. `HostBootstrap.Protected.withRunLiveness` takes a named kernel lock (`hTryLock`, which the OS
releases on process death) and holds it across **the sweep and the whole run**;
`Harness.Ownership` acquires it first, so:

- a competitor finds the lock held and is refused by a **stated** exclusion — "another test run is already
  in progress for this project" — instead of silently sweeping a live owner;
- a genuinely dead predecessor's lock is already released by the kernel, so it never blocks the next run,
  and the existing killed-mid-body case still passes unchanged;
- only the lock acquisition is wrapped in `try`. The body's own exceptions propagate unchanged, because
  the engine classifies them into report-card outcomes; the lock is still released on that path.

`HarnessSpec` now runs that four-process race as a standard case (~3 s), asserting exactly one acquisition,
three refusals, that every refusal states its cause, and that the winner released its generation.

Validation (2026-07-30): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **744**; the demo workspace passes **106** plus the embedded
**744**; the Python suite passes **231**; `git diff --check` is clean.

**Closed 2026-07-30 — `verifyDestroySettled` and the settled-destroy closure conversion.**

This was the one part of the terminal-close projection that could not be built here, because it must check
the **plan-derived destroy forest** Sprint 16.6 owns. That forest landed 2026-07-30
(`HostBootstrap.Teardown`), and with it:

- `verifyDestroySettled` accepts only a **completed `Destroy`** forest — the type refuses a `Down` one —
  and additionally refuses a forest that settled fewer nodes than the projection names, so a truncated
  traversal cannot pass as a settled destroy;
- `Lifecycle.Mode.destroySettledClosure` is the conversion this sprint owed: it consumes the
  `BoundRunLease`, `verifyAllSessionsClosed`'s completeness proof, and the `DestroySettled` proof,
  compares both against the lease's own plan digest, and mints
  `ProjectClosureEvidence SettledDestroyClose`.

Before this, `verifyNoProjectResourcesAcquired` was the **only** producer of `ProjectClosureEvidence`, so
the `SettledDestroyClose` branch was uninhabited: a Production project could release its mode after a
true pre-effect refusal but never after an actual `destroy`. The surrounding Closing/Closed machinery
delivered above was already complete and waiting for exactly this proof.

**Delivered 2026-08-02 — the two gates that had stopped observing what they claim to observe.**

Running the complete suite on an Apple Silicon macOS host — a substrate no prior gate in this sprint had
covered — surfaced two assertions that could no longer fail for the right reason:

- **The bound-snapshot assertion had a second, stale copy of the wire format.** `CLISpec`'s
  `observeBoundHarnessPlan` split the persisted snapshot record on tabs and expected
  `["1", spec, plan]`. The 2026-08-01 immutable-snapshot work replaced that layout with a versioned,
  length-framed binary record, so the assertion could not match **any** record the encoder writes and
  reported the whole payload as a disagreement. It now reads the record back through the shipped decoder
  (`Lifecycle.Mode.verifyPlanSnapshot`) instead of re-parsing bytes, so the test observes what production
  observes and cannot drift from the format again. Exporting the codec "for tests" was deliberately not
  done (§ EE).
- **The compile-fail matcher was comparing GHC's layout, not its content.** `SignHandoffWithoutRootStore`
  is rejected for exactly the intended reason — `signHandoffGrant` exists nowhere, because grant issuance
  must go through the root broker — but GHC wraps a diagnostic onto continuation lines once the inferred
  type is wide, so the expected `"Variable not in scope: signHandoffGrant"` never appeared as a literal
  substring. The matcher now collapses whitespace runs on both sides. That keeps each expectation exact in
  its tokens and their order while making it independent of a column budget; splitting the expectation
  into separate tokens was rejected, because an unrelated in-scope error on the same source line satisfies
  the split form and would have been a false green on the precise regression this fixture guards.

Neither is a weakening: the first replaces a private parser with the production one, and the second
removes a dependency on formatting that carries no semantic content.

Dated validation evidence (2026-08-02, Apple Silicon M1 Max, macOS 25.5.0 arm64, GHC 9.12.4): with these
two repairs the complete core suite passes **882/882** twice in a row under
`cabal test all --ghc-options=-Werror` from `core/`, and the demo workspace passes **110/110** demo tests
plus that embedded core suite; `poetry run python -m hostbootstrap.check_code` is clean and
`poetry run python -m hostbootstrap.test_all` passes **231**. (The same working tree carries Sprints 5.9,
11.10, and 16.6 landings that take the core suite to **888**; each records its own contribution.) This is
the **first complete core-suite pass recorded on Apple Silicon**, and it is a static gate only — it
exercises no live provider lane and closes none of the open items below.

**Still open (this sprint):** the authenticated authority-rehydration handoff and the versioned
session/fence prepare protocol shared with Sprints 15.9 and 16.6;
the `Conflict` and `Unsupported` report-card rows, which have no producer until the reconcilers are
wired at their call sites by Sprint 16.6; the receipt-carrying `ManagedResult Unchanged` / `ForeignResult`
half of the same bullet, which needs the same plan wiring; and the remainder of the concurrency/failure
matrix, whose kill-point and prepare/handoff clauses are stated against machinery Sprints 15.9 and 16.6
wire (the reservation-race clause above is now closed). Historical `6/6`, `8/8`, and `10/10` runs did not exercise these ownership or handoff races and do
not close the sprint.

### Sprint 10.10: Remove the parallel run-model representation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/dhall/Core.dhall`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/run_models.md`,
`documents/architecture/harness_workflow.md`,
`documents/architecture/dhall_generation.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make the project lifecycle plan the only execution representation. Remove the definition-only
`RunModel`/`RunModelKey`/`selectRunModel` Haskell path and the unconsumed `Core.dhall` `RunModel` union
instead of claiming either selects `project up`.

#### Deliverables

- Delete `RunModel`, `RunModelKey`, `selectRunModel`, their exports, and selector-only tests when no
  production consumer exists.
- Delete the `RunModel` union from `Core.dhall` and its aggregate export; no test or project config may
  carry an execution-mode literal alongside the project lifecycle plan.
- Retain only independently consumed primitives when repository search proves a real call path.
  Otherwise delete definition/test-only `oneShotSeams`, `defaultSeams`, `sliceBudget`,
  `guardTestDelete`, and `testCaseProfile` with the parallel selector surface; keep `oneShotRunArgs` only
  if the typed lifecycle plan consumes it directly.
- Describe `OneShot`, host-native, daemon/service, and cluster behavior as shapes expressed by typed
  lifecycle steps. If implementation later needs an explicit execution choice, it must be a consumed
  projection of the same typed plan, not a second selector.

#### Validation

- Repository search finds no `RunModel`, `RunModelKey`, `selectRunModel`, or Dhall `RunModel` definition
  outside dated history/ledger text.
- Core/Dhall schema and golden tests pass after removal, and project/harness tests prove `project up`
  still follows the same typed step plan.
- A structural single-representation test rejects adding an unconsumed execution selector beside the
  lifecycle plan.

**Passed 2026-07-25.** Repository search found none of the removed definitions or audited helper names
in core/demo source. `HarnessSpec`'s structural check and `DhallGenSpec`'s exact exported-type inventory
pass. Pinned Fourmolu and HLint are clean on every changed Haskell file; `cabal test all
--test-show-details=direct --ghc-options=-Werror` passes all **379 core tests**, and the demo workspace
passes both its project suite and the embedded 379-test core suite under `-Werror`.

#### Remaining Work

None. Phase 16.6 separately unifies the currently independent forward/topology/reverse lifecycle
callbacks.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - behavioral execution shapes expressed by the lifecycle plan;
  no parallel selector or Dhall execution field.
- `documents/architecture/harness_workflow.md` - the per-case loop, the seam-split (L0 driver vs app
  matrix), and the report card rendering a legible `LifecycleFailure` instead of
  `ExitFailure 1` (Sprint 10.8).
- `documents/architecture/readiness.md` - **(new)** the legible-failure contract (`LifecycleFailure`,
  stream-then-die) shared with the readiness discipline.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` - rewritten to the standardized harness and the `test` verb.

**Cross-references to add:**
- `system-components.md` adds the `HostBootstrap.Harness` row and the `test`/`check-code` verbs.
- `documents/engineering/code_check_doctrine.md` states `check-code` is a project-defined body.
