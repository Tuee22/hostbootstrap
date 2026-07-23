# Harness Workflow

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [composition_methodology](composition_methodology.md), [readiness](readiness.md), [development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md), [phase-19-generic-project-model.md](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)

> **Purpose**: Describe the one standardized test engine — the per-config `runMatrix` loop that drives
> the real `project up`, the seam-split between the L0 driver and project-supplied assertions, the two
> fail-closed safety preconditions, exclusive ownership locks, and the self-created-only delete-guard — and the root-gated `test init`
> / `test run` surface that drives it.

## TL;DR

- Every project's tests run through one engine: `runMatrix :: Seams env -> [Case] -> IO Report`.
- The harness **drives the real `project up`** rather than re-expressing bring-up. For each config variant
  it **generates** a test-specific `<project>.dhall` (functionally, via the project's own
  `projectConfigForRole` — it never shells the CLI), runs `project up` over the project's own chain, runs
  the case assertions, and tears the stack down with `project destroy` — the bring-up a test exercises is
  the **same chain** production uses, so no resource model can drift between test and deploy.
- A suite may declare **more than one config variant**. The harness stands each variant up, asserts, and
  tears it down **in turn** (full `project destroy` then a fresh `project up` between variants). The demo
  runs **two** variants — the default `message = "Hello, world!"` then a harness-generated
  `message = "Hello, Universe!"`.
- Assertions run **in the frame appropriate to each**, reusing the self-reference lift (e.g. a Playwright
  assertion as a container on the VM host network in the VM frame, outside the cluster). An assertion is
  **polymorphic over what the active variant set**: the harness exports `EXPECTED_MESSAGE` and the
  Playwright e2e-tabs spec asserts the SPA `#message` matches whatever the active deployment set, not a
  hardcoded string.
- Two **hard fail-fast safety preconditions** run before any test: refuse if the executable-sibling
  `<project>.dhall` (`siblingProjectConfigPath`, i.e. `.build/<project>.dhall`) already exists (never
  overwrite a production config), and refuse if a production cluster is running (never touch production
  state). Either → no tests run.
- Generated config and `.test_data` use exclusive ownership directories for the run lifetime. Ordinary
  config writers honor the same lock. A changed config is atomically quarantined and reported, never
  deleted as run-owned bytes. `SafetyRefusal` records a failed variant but performs no project teardown.
- Teardown runs via `finally`, and bring-up is bound **inside** it — a body (assertion) exception is
  recorded as `Fail`, never leaked, and teardown still runs; a failure *during* `project up` is covered too,
  because the Phase 16 guarded `applyChain` runs the same best-effort `project destroy` teardown at the ROOT
  frame, so a bring-up failure leaves no provider VM + in-VM cluster registered. An uncatchable process
  kill is handled by the next idempotent reconcile. Teardown removes **only** the
  `<project>.dhall` and the `.test_data` directory the harness created this run, never anything it found.
- The harness is the **one** representation of the test workflow because it *is* the deploy chain, driven
  with a test config. See [composition_methodology](composition_methodology.md) for the canonical model.

## The Per-Variant Loop

`runMatrix` groups the case list by config variant and, for each variant, runs the real lifecycle once.
When a suite declares more than one variant the loop repeats — full bring-up, assert, and teardown per
variant, in turn — so the demo's two messages each get their own fresh stack:

1. **Preconditions** — refuse to start unless it is safe: the executable-sibling `<project>.dhall`
   (`siblingProjectConfigPath`, i.e. `.build/<project>.dhall`) must not already exist (else a production
   config could be overwritten), and no production cluster may be running (else a live deployment could be
   disturbed). Either condition fails the run before any side effect; no tests run.
2. **Generate config** — build the variant's `<project>.dhall` **functionally** via the project's own
   `projectConfigForRole` (the same value-taking assembler `project init` reaches through `psInit`),
   applying the variant's
   `test.dhall` overrides through `psTestConfig`, and write it next to the executable. The harness never
   shells `project init`.
3. **`project up`** — interpret the project's own `chain :: cfg -> [Step]` recursively across the
   composed frame stack, exactly as a production deploy does.
4. **Assertions** — run that variant's case bodies against the live stack, each in the frame appropriate to
   it (reusing the self-reference lift, [§ U](../../DEVELOPMENT_PLAN/development_plan_standards.md)).
   Assertions are **polymorphic over what the variant set**: the harness exports `EXPECTED_MESSAGE` and the
   Playwright e2e-tabs spec asserts the SPA `#message` matches it, so the same spec proves both the
   `"Hello, world!"` and `"Hello, Universe!"` deployments.
5. **`project destroy`** — runs via `finally` with bring-up (step 3) bound **inside** it, so it executes
   whether bring-up fails or the assertion bodies succeed, fail, or throw, then removes the generated
   `<project>.dhall` and the `.test_data` the harness created this run. The next variant then spins up a
   fresh stack. A failure *inside* step 3 is covered too: the Phase 16 guarded `applyChain` runs the same
   `project destroy` teardown at the ROOT frame, so it leaves no VM registered. Independent cleanup steps
   are all attempted and failures aggregate; a teardown failure marks the variant failed. An external hard
   kill is handled by the idempotent next-up reconcile.

A body exception is caught and recorded as a `Fail` in the per-case result; it is never leaked out of
`runMatrix`. The per-case results aggregate into a `Report`. `reportCard` renders the report (the bare
binary's empty matrix renders `test report: 0/0 passed`) and `allPassed` checks it.

A bring-up failure is carried the same way a refusal is: as a structured `LifecycleFailure` — the peer of
the `SafetyRefusal` round-trip — that crosses the self-reference subprocess boundary and the harness catch
carrying its cause, and `reportCard` renders that cause with `displayException`, so a failed variant
**states why it failed** rather than collapsing to a message-less `ExitFailure 1`. This is the
legible-failure half of the `Ready`-witness discipline ([readiness](readiness.md)); it is **reopened work**
(phase-10 Sprint 10.8), not yet delivered — a bring-up failure today still renders as `ExitFailure 1`.

Test durable storage is always `.test_data`, never `.data` (the production data directory); see
[cluster lifecycle](../engineering/cluster_lifecycle.md) for the production-versus-test profile
distinction.

## The `test init` / `test run` Surface

The test surface is a **separate command pair**, gated to the **root** (host-orchestrator) frame:

- `test init` writes a `test.dhall` from the project's own `psTestInit` builder (the demo's
  `demoTestInit`, seeded from the project's default resources), so it **needs no pre-existing
  `<project>.dhall`**. That file is the test DSL — the case
  matrix plus thin config overrides (resources, secrets, the message variant) to pass through to the normal
  binary — but it never re-derives the lift chain; the chain is the project's `[Step]` value, owned by
  `project up`.
- `test run <case-id>` runs that single case; `test run all` runs the project's **whole** case matrix
  (the positional metavar is `SUITE`, with `all` the reserved whole-matrix selector). Both require
  `test.dhall`; an unknown selector fails fast, listing the valid case ids and `all`.

`all` is reserved by the verb, so a project may not name a suite `all`. A project supplies its `Case`s and
`assertCase` bodies as a non-empty `TestSuite` so the cases run under `test run`, not a per-noun subcommand.

The surface **drives** deploy rather than duplicating it. `project up` interprets the project chain to
stand up a persistent stack (VM → project image → kind → registry → webservice/`service run`, exposed to
the host); `test run` runs that same `project up` under a test config, asserts, and tears it down. There
is no parallel `seamSetup` that stands up a cluster a second way.

## The Seam-Split

The engine is split so the reusable driver is written once and projects supply only what is genuinely
project-specific:

| Layer | What it owns | Lives in |
|-------|--------------|----------|
| L0 driver | The `runMatrix` loop, the preconditions, the `project up`/`project destroy` lifecycle, the self-created-only delete-guard, and report aggregation. | `HostBootstrap.Harness` (core) |
| Project assertions | The `TestSuite`'s `assertCase` field — the per-case assertion bodies run against the live stack, plus any case-specific setup that is *assertion*, not bring-up. (`Seams` is the internal L0 adapter the driver builds, not authored here.) | The project |
| App matrix | The list of `Case`s and the per-config overrides, packaged as a `TestSuite`. | The app |

A project supplies one `TestSuite` (safety / bringUp / [Case] / assertCase / tearDown), **not** a `Seams`
value. The bring-up and teardown a case needs are the **real** `project up` / `project destroy` the L0
driver runs, not a project-supplied second path; `Seams env = { seamSetup, seamRun, seamTeardown }` is the
internal L0 adapter `runSuiteSelection` constructs (`assertSeams`), with `seamSetup` (`\_ -> pure env`) and
`seamTeardown` (a no-op) driver-fixed and only `seamRun` bound to the suite's project-authored `assertCase`
— the **assertions** that prove the live stack, run in the appropriate frame through the self-reference
lift. The app never re-implements the loop, the preconditions, or the guard.

## Never-Touch-Production Is Mechanical

The harness cannot disturb or delete production state, enforced in code rather than by convention:

- **The two preconditions.** Before any side effect, the run refuses if the executable-sibling
  `<project>.dhall` (`siblingProjectConfigPath`, i.e. `.build/<project>.dhall` — **not** the project root)
  already exists (it would have to overwrite a real config) or if a production cluster is running (it would
  share the host with a live deployment). Both are checked up front; failing either aborts the run.
- **Exclusive ownership plus the self-created-only delete-guard.** Config and `.test_data` ownership
  directories serialize runs. Teardown removes only the generated `<project>.dhall` and the
  `.test_data` directory the harness *created this run*, tracked from the act of creating them — never a
  config or data directory it found. This mirrors the never-delete-`.data` invariant in
  [cluster lifecycle](../engineering/cluster_lifecycle.md): `project destroy`'s cluster-teardown removal
  set never names `.data`, and the harness additionally never deletes anything it did not author. If
  config bytes differ during cleanup, they remain in the locked ownership quarantine and the variant
  fails for explicit recovery.
- **Distinguished safety refusal.** Missing tools/probe failures fail closed. A `SafetyRefusal` means the
  state is provably pre-existing; the harness reports it but skips project teardown.

> **WRONG**
>
> Teardown removes the sibling config unconditionally:
>
> ```haskell
> seamTeardown = \_ -> removeFile "<project>.dhall"
> ```
>
> This is wrong because a run that found a pre-existing (production) config would delete it. The
> preconditions already refuse to start in that case, and teardown only ever removes what *this run*
> created — together that is what makes "never touch production" mechanical rather than a reviewer's
> promise.

> **RIGHT**
>
> The run refuses up front and deletes only its own artifacts:
>
> ```haskell
> ensureNoExistingConfig siblingProjectConfigPath  -- refuse if .build/<project>.dhall already exists
> ensureNoProductionClusterRunning                 -- refuse if a production cluster is live
> created <- writeTestConfig (projectConfigForRole args)  -- generate functionally; record what we authored
> projectUp `finally` (projectDestroy >> removeOnlyCreated created)
> ```

## Budget

Each test configuration carries the project budget (with any test overrides), and `project up` sizes the
stack from it through the one canonical path: the budget **is the VM wall**, and the in-VM cluster is a
**slice within it** (no budget-sized headroom — see [resource budgeting](../engineering/resource_budgeting.md)).
Because tests use the production sizing path, a config that fits a host's capacity is the same fact for
both deploy and test. `fitsBudget` (from `HostBootstrap.Cluster.Cordon`) proves the pod set fits the
slice before bring-up.

## Current Status

The `project up`-driven harness, fail-closed preconditions, ownership locks, the self-created-only delete-guard, and `web
serve` → `service run` are implemented. The `HostBootstrap.Harness` `runMatrix` loop, report aggregation,
data-preserving teardown, harness-generated configs, multi-variant loop, and polymorphic message assertion
are exercised by the core and demo tests and closed in
[phase-19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md) and
[phase-20](../../DEVELOPMENT_PLAN/phase-20-config-driven-demo-worked-example.md).

Under [development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md), `test run`
does not drive `project up` against a pre-existing config. Instead it GENERATES the run's `<project>.dhall`
**functionally** from a thin `test.dhall` override via the project-owned `psTestConfig` (which reuses the
project's `projectConfigForRole`/`psInit` builder — never shelling `project init`), drives the real
`project up` over that generated config, and on teardown removes only its still-owned config bytes plus the
`.test_data` it created while keeping the authored `test.dhall`. Changed bytes are quarantined and reported.
A suite may declare more than one
variant; the harness stands each up, asserts (with `EXPECTED_MESSAGE` parameterizing the assertion), and
tears it down in turn. The fail-fast precondition checks the executable-sibling `siblingProjectConfigPath`
(`.build/<project>.dhall`), not the project root. See the
[generic_project_model.md](generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## See Also

- [composition_methodology](composition_methodology.md) — the canonical home of the chain/lift model the
  test workflow drives.
- [run models](run_models.md) — the four run-models, including the service/daemon leaf reached via
  `service run`.
- [testing](../engineering/testing.md) — the `test init` / `test run` surface that drives `runMatrix`.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the test-profile semantics and the
  `.data`-preserving teardown partition.
- [resource budgeting](../engineering/resource_budgeting.md) — the budget = VM wall, cluster = slice rule.
