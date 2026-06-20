# Harness Workflow

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [composition_methodology](composition_methodology.md), [development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)

> **Purpose**: Describe the one standardized test engine — the per-config `runMatrix` loop that drives
> the real `project up`, the seam-split between the L0 driver and project-supplied assertions, the two
> fail-fast safety preconditions, and the self-created-only delete-guard — and the root-gated `test init`
> / `test run` surface that drives it.

## TL;DR

- Every project's tests run through one engine: `runMatrix :: Seams env -> [Case] -> IO Report`.
- The harness **drives the real `project up`** rather than re-expressing bring-up. Per **distinct test
  configuration** it writes a test-specific `<project>.dhall`, runs `project up` over the project's own
  chain, runs the case assertions, and tears the stack down with `project destroy` — the bring-up a test
  exercises is the **same chain** production uses, so no resource model can drift between test and deploy.
- **One `project up` per distinct test config.** Cases that share a config assert against that one live
  stack; a case needing different resources/secrets declares a different config and gets its own fresh
  stack.
- Assertions run **in the frame appropriate to each**, reusing the self-reference lift (e.g. a Playwright
  assertion as a container on the kind network in the VM frame, outside the cluster).
- Two **hard fail-fast safety preconditions** run before any test: refuse if a `<project>.dhall` already
  exists (never overwrite a production config), and refuse if a production cluster is running (never touch
  production state). Either → no tests run.
- Teardown ALWAYS runs via `finally`; a body exception is recorded as `Fail`, never leaked. Teardown
  removes **only** the `<project>.dhall` and the `.test_data` directory the harness created this run, never
  anything it found.
- The harness is the **one** representation of the test workflow because it *is* the deploy chain, driven
  with a test config. See [composition_methodology](composition_methodology.md) for the canonical model.

## The Per-Config Loop

`runMatrix` groups the case list by test configuration and, for each distinct config, runs the real
lifecycle once:

1. **Preconditions** — refuse to start unless it is safe: a sibling `<project>.dhall` must not already
   exist (else a production config could be overwritten), and no production cluster may be running (else a
   live deployment could be disturbed). Either condition fails the run before any side effect; no tests
   run.
2. **Write config** — project the test configuration (resource/secret overrides) into a normal,
   test-specific `<project>.dhall` next to the executable.
3. **`project up`** — interpret the project's own `chain :: ProjectConfig -> [Step]` recursively across the
   composed frame stack, exactly as a production deploy does.
4. **Assertions** — run that config's case bodies against the live stack, each in the frame appropriate to
   it (reusing the self-reference lift, [§ U](../../DEVELOPMENT_PLAN/development_plan_standards.md)).
5. **`project destroy`** — ALWAYS runs, wired through `finally` so it executes whether the bodies succeed,
   fail, or throw, then removes the `<project>.dhall` and `.test_data` the harness created this run.

A body exception is caught and recorded as a `Fail` in the per-case result; it is never leaked out of
`runMatrix`. The per-case results aggregate into a `Report`. `reportCard` renders the report (the bare
binary's empty matrix renders `test report: 0/0 passed`) and `allPassed` checks it.

Test durable storage is always `.test_data`, never `.data` (the production data directory); see
[cluster lifecycle](../engineering/cluster_lifecycle.md) for the production-versus-test profile
distinction.

## The `test init` / `test run` Surface

The test surface is a **separate command pair**, gated to the **root** (host-orchestrator) frame:

- `test init` requires an existing `project.dhall` and writes a sibling `test.dhall`. That file is the
  test DSL — the case matrix plus config overrides (resources, secrets) to pass through to the normal
  binary — but it never re-derives the lift chain; the chain is the project's `[Step]` value, owned by
  `project up`.
- `test run <suite>` runs the named suite; `test run all` is always a suite that runs the project's
  **whole** case matrix. Both require `test.dhall`; an unknown suite fails fast, listing the valid suite
  names and `all`.

`all` is reserved by the verb, so a project may not name a suite `all`. A project supplies its `Case`s and
`Seams` as a non-empty `TestSuite` so the cases run under `test run`, not a per-noun subcommand.

The surface **drives** deploy rather than duplicating it. `project up` interprets the project chain to
stand up a persistent stack (VM → project image → kind → harbor → webservice/`service run`, exposed to
the host); `test run` runs that same `project up` under a test config, asserts, and tears it down. There
is no parallel `seamSetup` that stands up a cluster a second way.

## The Seam-Split

The engine is split so the reusable driver is written once and projects supply only what is genuinely
project-specific:

| Layer | What it owns | Lives in |
|-------|--------------|----------|
| L0 driver | The `runMatrix` loop, the preconditions, the `project up`/`project destroy` lifecycle, the self-created-only delete-guard, and report aggregation. | `HostBootstrap.Harness` (core) |
| Project assertions | The `Seams` record — per-case assertion bodies (`seamRun`) run against the live stack, plus any case-specific setup that is *assertion*, not bring-up. | The project |
| App matrix | The list of `Case`s and the per-config overrides, packaged as a `TestSuite`. | The app |

`Seams env = { seamSetup, seamRun, seamTeardown }`. The bring-up and teardown a case needs are the **real**
`project up` / `project destroy` the L0 driver runs, not a project-supplied second path; the project's
seams carry the **assertions** that prove the live stack, run in the appropriate frame through the
self-reference lift. The app never re-implements the loop, the preconditions, or the guard.

## Never-Touch-Production Is Mechanical

The harness cannot disturb or delete production state, enforced in code rather than by convention:

- **The two preconditions.** Before any side effect, the run refuses if a `<project>.dhall` already exists
  (it would have to overwrite a real config) or if a production cluster is running (it would share the
  host with a live deployment). Both are checked up front; failing either aborts the run.
- **The self-created-only delete-guard.** Teardown removes only the `<project>.dhall` and the `.test_data`
  directory the harness *created this run*, tracked from the act of creating them — never a config or data
  directory it found. This mirrors the never-delete-`.data` invariant in
  [cluster lifecycle](../engineering/cluster_lifecycle.md): `project destroy` already preserves `.data`,
  and the harness additionally never deletes anything it did not author.

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
> ensureNoExistingConfig            -- refuse if <project>.dhall already exists
> ensureNoProductionClusterRunning  -- refuse if a production cluster is live
> created <- writeTestConfig cfg    -- record what we authored this run
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

The `project up`-driven harness, the two preconditions, the self-created-only delete-guard, and `web
serve` → `service run` are the **target** model. The implemented surface today still uses per-case
isolated kind clusters via `seamSetup` bring-up; the migration to driving `project up` is tracked as
real-run-gated `Active` work in
[phase-10](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md),
[phase-13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md), and
[phase-17](../../DEVELOPMENT_PLAN/phase-17-chain-driven-test-and-context-introspection.md). The
`HostBootstrap.Harness` `runMatrix` loop, the report aggregation, and the data-preserving teardown are
exercised by the core test suite.

## See Also

- [composition_methodology](composition_methodology.md) — the canonical home of the chain/lift model the
  test workflow drives.
- [run models](run_models.md) — the four run-models, including the service/daemon leaf reached via
  `service run`.
- [testing](../engineering/testing.md) — the `test init` / `test run` surface that drives `runMatrix`.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the test-profile semantics and the
  `.data`-preserving teardown partition.
- [resource budgeting](../engineering/resource_budgeting.md) — the budget = VM wall, cluster = slice rule.
