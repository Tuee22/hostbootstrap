# Harness Workflow

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)

> **Purpose**: Describe the one standardized test engine — the per-case `runMatrix` loop, the
> seam-split between the L0 driver and project-supplied seams, the mechanical never-touch-production
> guard, and budget-slicing.

## TL;DR

- Every project's tests run through one engine: `runMatrix :: Seams env -> [Case] -> IO Report`.
- The per-case loop is `seamSetup` → `seamRun` → `seamTeardown`, with teardown ALWAYS running via
  `finally`; a body exception is recorded as `Fail`, never leaked.
- The seam-split is the whole point: the L0 driver (loop, isolation, delete-guard, budget-slicing,
  report) lives once in core; cluster projects supply kind/Helm `Seams`; the app supplies only its
  case matrix.
- Never-touch-production is mechanical: `guardTestDelete` refuses any cluster name without the
  project's test prefix, and the pure `teardown` partition keeps `.data` out of the removal set.
- `sliceBudget` keeps the matrix within the project ceiling — divisible cases split by weight,
  indivisible cases run serially at the full budget.

## The Per-Case Loop

`runMatrix` walks the case list and, for each `Case`, runs three seams in order:

1. `seamSetup` spins up an isolated environment for the case.
2. `seamRun` runs the case body against that environment.
3. `seamTeardown` ALWAYS runs, wired through `finally` so it executes whether the body succeeds,
   fails, or throws.

A body exception is caught and recorded as a `Fail` in the per-case result; it is never leaked out of
`runMatrix`. The per-case results aggregate into a `Report`. `reportCard` renders the report (the bare
binary's empty matrix renders `test report: 0/0 passed`) and `allPassed` checks it.

Each case runs against an isolated per-case profile. `Case = { caseId, caseWeight, caseIndivisible }`,
and `testCaseProfile c = TestCase (caseId c)` derives the profile: cluster name
`<project>-test-<case>` and data root `./.test_data/<case>/`. Isolation is what lets cases run without
endangering production state or each other; see [cluster lifecycle](../engineering/cluster_lifecycle.md)
for the production-versus-test profile distinction the harness drives.

## The Seam-Split

The engine is split so the reusable driver is written once and projects supply only what is genuinely
project-specific:

| Layer | What it owns | Lives in |
|-------|--------------|----------|
| L0 driver | The `runMatrix` loop, per-case isolation, the delete-guard, budget-slicing, and report aggregation. | `HostBootstrap.Harness` (core) |
| Project seams | The `Seams` record — `seamSetup` / `seamRun` / `seamTeardown` for the project's substrate. | The project (cluster projects supply kind/Helm seams) |
| App matrix | The list of `Case`s to run. | The app |

`Seams env = { seamSetup, seamRun, seamTeardown }`. The default L0 `defaultSeams` does a one-shot
container run (the `OneShot` run-model from [run models](run_models.md)); a cluster project supplies
kind/Helm seams instead (the `Cluster` model). The app never re-implements the loop, the isolation, or
the guard — it supplies its case matrix, and a cluster project additionally supplies its seams.

## Never-Touch-Production Is Mechanical

The harness cannot delete production state, and that is enforced in code rather than by convention,
across two mechanisms:

- **The prefix delete-guard.** `guardTestDelete prefix name` refuses any cluster name that does not
  carry the project-supplied test prefix, returning `Left (NotPrefixed …)`. The test-profile teardown
  routes deletes through this guard, so a name like a production cluster name is rejected before any
  removal runs.
- **The data-preserving teardown partition.** The pure `teardown` partition in
  `HostBootstrap.Cluster.Lifecycle` keeps `.data` out of the removal set for both `down` and `delete`.
  Tearing a case down removes the cluster and its compute, never its data directory.

> **WRONG**
>
> The teardown deletes by exact cluster name with no prefix check:
>
> ```haskell
> seamTeardown = \env -> deleteCluster (clusterName env)
> ```
>
> This is wrong because nothing prevents a misconfigured case from naming — and deleting — a
> production cluster; the guard is exactly what makes "never touch production" mechanical rather than
> a reviewer's promise.

> **RIGHT**
>
> The teardown routes the name through `guardTestDelete` first:
>
> ```haskell
> seamTeardown = \env ->
>   case guardTestDelete testPrefix (clusterName env) of
>     Left (NotPrefixed n) -> refuse n       -- production name: refuse, never delete
>     Right safe           -> deleteCluster safe
> ```
>
> A non-prefixed name is rejected before any removal, and the `teardown` partition still keeps `.data`
> out of whatever does get removed.

## Budget-Slicing

`sliceBudget budget cases` keeps the whole matrix within the project's ceiling. The slice depends on
each case's `caseWeight` and `caseIndivisible` flag:

- **Divisible cases** split the budget proportionally to `caseWeight` via `splitByWeight`, which uses
  floor division so the concurrent slices never overcommit the budget.
- **Indivisible cases** (`caseIndivisible = True`, e.g. a GPU case) each receive the FULL budget and
  run serially at concurrency 1, because they cannot share their resource.

`fitsBudget` (from `HostBootstrap.Cluster.Cordon`) proves the concurrent set actually fits the budget
before the cases run. The budget itself, the canonical quantity parser, and the cordon rings are
documented in [resource budgeting](../engineering/resource_budgeting.md) and
[applied cordon](../engineering/applied_cordon.md).

## See Also

- [run models](run_models.md) — the four models the `Seams` realize and how a model is selected.
- [testing](../engineering/testing.md) — the `test` verb that drives `runMatrix` over the project matrix.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the test-profile semantics and the
  `teardown` partition.
- [resource budgeting](../engineering/resource_budgeting.md) — the budget `sliceBudget` divides.
