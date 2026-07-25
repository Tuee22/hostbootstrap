# Phase 10: Standardized test harness and run-models

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
validated, while `RunModel`/`RunModelKey`/`selectRunModel` and `Core.dhall`'s `RunModel` union form an
unconsumed parallel model beside the chain. Historical run counts below do not close those gaps.

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

The earlier `runMatrix :: Seams env -> [Case] -> IO Report` engine supplied a per-case naming convention
(`testCaseProfile` / `.test_data`) and `finally`-based cleanup. Those path prefixes are not exclusive
ownership, and the demo's compiled suite still resolves a Production plan; Sprint 10.9 replaces both with
opaque `Harness projectId runId` authority and receipts. Historical `guardTestDelete`/teardown tests remain useful
negative evidence but do not make current never-touch-production mechanical.
`sliceBudget` divides the budget across divisible cases by weight (`splitByWeight`, floor) while
indivisible (GPU) cases each get the full budget at concurrency 1. The code still defines and tests
`RunModel`, `RunModelKey`, and `selectRunModel`, and `Core.dhall` still exports a duplicate `RunModel`
union, but no production path consumes either representation to drive `project up`. Sprint 10.10 removes
them rather than pretending they select execution. The L0 `OneShot` helpers include the pure
`oneShotRunArgs` argv and executable `oneShotSeams` IO seam, but `oneShotSeams` is definition-only: no
production or test caller wires it into `project up`. Sprint 10.10 removes it unless a real consumer is
introduced. `runMatrix` isolates a
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
functional logic (the case matrix and delete-guard) and the chain production uses. The public
`sliceBudget` helper is definition/test-only and is not called by this engine. The engine recast to drive
the real `project up` landed in code and is
real-run-validated; the last completed pre-accelerator `test run all` reported `6/6 passed` (phase-20's
second message variant brought the earlier single-variant `3/3` matrix to `6/6`; the dated 2026-06-20
`3/3` validation below stands). Those are dated matrix snapshots, not current ownership/concurrency
closure.

## Remaining Work

**Current:** Sprint 10.9 is Blocked by Sprints 5.7, 9.10, 15.9, and 19.6–19.8, then owns
resource-authoritative reservations/ownership, per-variant failure isolation, structured cleanup
outcomes, and authenticated cross-process harness-authority handoff. The dated
closure record below does not cover concurrent acquisition, identity-bearing teardown, or authority
rehydration in the self-invoked `project up`.

**Current:** Sprint 10.10 is Planned to remove the unconsumed `RunModel` selector/type and Dhall union, then
make the project lifecycle plan the only execution representation.

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
project-owned, independent `psTestConfig` callback. The demo calls a helper also used by `psInit` by
convention; core does not enforce that reuse. The harness deletes only bytes that still match the generated
payload under the current cooperative sidecar guard; changed bytes remain in the reported locked
quarantine. That byte match is neither a resource-authoritative reservation nor a verified
identity-bearing ownership receipt (Sprint 10.9). The
superseded `test`-reuses-existing-config flow is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner. **This phase built
forward through phase 19 and was not reopened for it; it is reopened 2026-07-21 for legible lifecycle failure
(Sprint 10.8, below).**

The split command surface (`test init` / `test run <case-id>|all`) and the live harness engine
(`TestSuite`/`runMatrix`, the data-preserving `teardown` partition, and `seamSetup`-in-`try` isolation)
are built and unit-tested. `sliceBudget`, `guardTestDelete`, `testCaseProfile`, `defaultSeams`, and
`oneShotSeams` are definition/test-only compatibility helpers, not consumed production cores; Sprint
10.10 removes them unless a real plan-owned call path is introduced.

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

**Richer `<project>.test.dhall` landed (2026-06-20), code-check-validated:** `<project>.test.dhall` is now a reflected record
`{ testSuites : List Text, testResources : { cpu, memory, storage } }` (`HostBootstrap.Config.Schema.TestConfig`,
`defaultTestConfig` / `renderTestConfig` / `decodeTestConfigFile`), carrying per-test **resource overrides**
alongside the selectable suites. `test init` writes it (seeded from the project config's resources, with
an encoder-declared schema); `test run` decodes it and reports the test-config resources before running.
`SchemaSpec` covers the render→decode round trip, while Phase 8 Sprint 8.7 owns construction-time
encoder/decoder type-expression equality. A consumer edits `testResources` to run its tests at a different budget
than production; the demo runs at its declared budget (its test resources equal its config's, since its full
lifecycle needs the full budget). Secrets are intentionally not carried as plaintext in `<project>.test.dhall` (the
credential-forwarding doctrine keeps secrets out of Dhall, § U).

The `project up` interpreter the engine drives is owned by
[phase-16](phase-16-project-lifecycle-command.md); the test surface that invokes the engine is
co-owned with [phase-17](phase-17-chain-driven-test-and-context-introspection.md).

## Phase Objective

Provide the reusable test workflow and execution-shape taxonomy (see
[development_plan_standards.md § S, T](development_plan_standards.md)). Isolation, the delete-guard, the
profile/path derivation, and report aggregation live once in L0; the app supplies the matrix.
`sliceBudget` is currently only a pure definition/test seam and does not schedule or constrain the
runtime matrix. Phase 10.9 makes never-touch-production mechanical and derives any effective per-run
budget from the actual plan; Phase 10.10 removes the unused parallel run-model representation.

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
resource-authoritative plan work introduces a real consumer; Sprints 9.10/10.9 own the applied workload
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

### Sprint 10.9: Exclusive test ownership and failure isolation [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 5.7, 9.10, 15.9, and 19.6–19.8
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/testing.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make a test run an exclusively owned transaction whose failures are isolated per variant and whose
cleanup cannot delete foreign or concurrently replaced state.

#### Deliverables

- Acquire a resource-specific authoritative reservation plus conditional mutation/delete before strong
  ownership is claimed: a retained bound socket for ports, an OS-enforced lock/lease for host daemons,
  and provider create-if-absent/CAS plus immutable generation for VMs/clusters. For generated config and
  `.test_data`, bare exclusive create/rename or compare-then-unlink is insufficient against same-privilege
  replacement; only a protected namespace with an identity-bound kernel operation may mint a strong
  receipt. A local sidecar/cooperative lock remains a weaker mode. A backend without the full primitive
  reports `Unsupported`.
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

Blocked until Sprints 5.7, 9.10, 15.9, and 19.6–19.8 land the provider/storage receipt primitives, opaque
state/result algebra, independent root authority, typed matrix, scoped assembler/codec, and finalized plan. This sprint owns the
fresh and bound-recovery lifecycle mode/profile openers rather than depending on Phase 5 to construct
them. Then replace
cooperative/path-based ownership with resource-authoritative reservations and verified receipts,
implement the authenticated
authority-rehydration handoff, thread the structured results through the report card, and run the
concurrency/failure matrix. Historical `6/6` and `8/8` runs did not exercise these ownership or handoff
races and do not close the sprint.

### Sprint 10.10: Remove the parallel run-model representation [Planned]

**Status**: Planned
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

#### Remaining Work

Remove the dead Haskell and Dhall surfaces, prune or wire independently useful one-shot primitives, update
the governed run-model narrative, and run the full static gate. Phase 16.6 separately unifies the currently
independent forward/topology/reverse lifecycle callbacks.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - behavioral execution shapes expressed by the lifecycle plan;
  no parallel selector or Dhall `RunModel` field.
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
