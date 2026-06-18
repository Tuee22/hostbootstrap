# Harness Workflow

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [composition_methodology](composition_methodology.md), [development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)

> **Purpose**: Describe the one standardized test engine — the per-case `runMatrix` loop, the
> seam-split between the L0 driver and project-supplied seams, the mechanical never-touch-production
> guard, and budget-slicing — and the root-gated `test init` / `test run` surface that drives it
> against the live `project up` stack.

## TL;DR

- Every project's tests run through one engine: `runMatrix :: Seams env -> [Case] -> IO Report`.
- The per-case loop is `seamSetup` → `seamRun` → `seamTeardown`, with teardown ALWAYS running via
  `finally`; a body exception is recorded as `Fail`, never leaked.
- The seam-split is the whole point: the L0 driver (loop, isolation, delete-guard, budget-slicing,
  report) lives once in core; cluster projects supply kind/Helm `Seams`; the app supplies only its
  case matrix.
- The test surface is a **separate, root-gated** command pair — `test init` writes `test.dhall`,
  `test run <suite>|all` drives `runMatrix` — **decoupled** from the deploy chain. `project up` stands
  up the persistent stack; `test run all` is its own validation surface and does not run as part of
  bringing the stack up.
- Never-touch-production is mechanical: `guardTestDelete` refuses any cluster name without the
  project's test prefix, and the pure `teardown` partition keeps `.data` out of the removal set.
- `sliceBudget` keeps the matrix within the project ceiling — divisible cases split by weight,
  indivisible cases run serially at the full budget.
- The harness is **context-agnostic**: its seams call `clusterUp` (and the per-case deploy/e2e)
  "locally", with no `LiftContext` inside the engine. It is therefore a **lift target** — `test run
  all` lifts the whole workflow into the project container in the VM, and each case's isolated kind
  cluster comes up wherever the harness lands. The harness is the **one** representation of the test
  workflow. See [composition_methodology](composition_methodology.md) for the canonical model.

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

## The `test init` / `test run` Surface

The test surface is a **separate command pair**, gated to the **root** (host-orchestrator) frame and
to a project that already owns a `project.dhall`:

- `test init` requires an existing `project.dhall` and writes a sibling `test.dhall`. That file may
  carry test-specific configuration (matrix budget, suite parameters), but it never re-derives the
  lift chain — the chain is the project's `[Step]` value, owned by `project up`.
- `test run <suite>` runs the named suite; `test run all` is always a suite that runs the project's
  **whole** case matrix. Both require `test.dhall`; an unknown suite fails fast, listing the valid
  suite names and `all`.

`all` is reserved by the verb, so a project may not name a suite `all`. A project supplies its `Case`s
and `Seams` as a non-empty `TestSuite` so the cases run under `test run`, not a per-noun subcommand.

The pair is **decoupled from deploy**. `project up` brings up a persistent stack (VM → project image →
kind → harbor → webservice, exposed to the host); it does not run tests as part of standing the stack
up. `test run all` is a separate validation pass that runs root-gated and on demand. The stack is
durable, and the test surface drives its own isolated per-case kind clusters independently of it.

## The Seam-Split

The engine is split so the reusable driver is written once and projects supply only what is genuinely
project-specific:

| Layer | What it owns | Lives in |
|-------|--------------|----------|
| L0 driver | The `runMatrix` loop, per-case isolation, the delete-guard, budget-slicing, and report aggregation. | `HostBootstrap.Harness` (core) |
| Project seams | The `Seams` record — `seamSetup` / `seamRun` / `seamTeardown` for the project's substrate. | The project (cluster projects supply kind/Helm seams) |
| App matrix | The list of `Case`s to run, packaged as a `TestSuite`. | The app |

`Seams env = { seamSetup, seamRun, seamTeardown }`. The default L0 `defaultSeams` does a one-shot
container run (the `OneShot` run-model from [run models](run_models.md)); a cluster project supplies
kind/Helm seams instead (the `Cluster` model). The app never re-implements the loop, the isolation, or
the guard — it supplies its case matrix, and a cluster project additionally supplies its seams.

The seams call `clusterUp` (and the per-case deploy/e2e) **"locally"** — they hold no execution-context
parameter and are unaware of any enclosing lift. A consumer that needs the cluster to come up elsewhere
(say on a VM's Docker) runs `test run all` so the **whole** workflow lifts into that context (through
the selected VM provider and then `docker run --rm <image> test run all`), and the seams run as if
local so the cluster lands wherever the harness was lifted to. This is why the harness is a lift target,
not a lift-aware component, and why a separate chain of lifted cluster/deploy/e2e ops alongside it would
be a redundant second representation. See [composition_methodology](composition_methodology.md).

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

## Current Status

The root-gated **`test init` / `test run <suite>|all`** pair backs the harness with a sibling
`test.dhall` and stays **decoupled** from the persistent `project up` stack. `project up` interprets the
project's `chain :: ProjectConfig -> [Step]` recursively across the composed frame stack to stand up the
durable stack (VM → project image → kind → harbor → webservice, exposed to the host); `test run all`
drives `runMatrix` over the project's case matrix as a separate validation surface with its own isolated
per-case kind clusters.

The `HostBootstrap.Harness` engine (the `runMatrix` loop, the seam-split, the prefix delete-guard,
budget-slicing) is the one engine the surface drives. Root-gating, the prefix delete-guard, the
data-preserving teardown partition, and budget-slicing are exercised by the core test suite. The
[development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md) records the test surface
and the deploy/test decoupling.

## See Also

- [composition_methodology](composition_methodology.md) — the canonical home of the chain/lift model
  the test workflow is a lifted operation of.
- [run models](run_models.md) — the four models the `Seams` realize and how a model is selected.
- [testing](../engineering/testing.md) — the `test init` / `test run` surface that drives `runMatrix`
  over the project matrix.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the test-profile semantics and the
  `teardown` partition.
- [resource budgeting](../engineering/resource_budgeting.md) — the budget `sliceBudget` divides.
