# Testing

**Status**: Authoritative source
**Supersedes**: the pure-Python pytest/`test_all` suite description (spec/model/CLI-smoke layers)
**Referenced by**: [../README.md](../README.md), [code_check_doctrine.md](code_check_doctrine.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: Describe how hostbootstrap is tested across its Haskell `hostbootstrap-core` library
> and its thin Python bootstrapper, where the `test` surface sits relative to the project chain, and
> where the documentation validator fits.

## TL;DR

- Every project's tests run through one standardized engine — `runMatrix` over a `Seams` record — and
  the `test` surface prints its report card. The mechanics live once in `HostBootstrap.Harness`; the
  app supplies only its case matrix. See
  [../architecture/harness_workflow.md](../architecture/harness_workflow.md).
- The `test` surface is two root-frame subcommands: `test init` writes the project's
  `<project>.test.dhall`, and `test run <suite>|all` runs one named suite (or every suite via the
  reserved `all`).
- `hostbootstrap-core` (Haskell) carries the bulk of the unit-test surface: host-tool resolution,
  substrate detection, the `ensure` reconcilers' pure decision logic, the project-local Dhall config
  decoder/generator, cluster-lifecycle semantics, the harness driver, and the documentation
  validator.
- The thin Python bootstrapper carries a small, hermetic test surface for the pre-binary
  bootstrapping steps it owns.
- A mechanical documentation validator (`HostBootstrap.DocValidator`) is a `hostbootstrap-core`
  quality gate that runs through `cabal test`.
- The default unit-test run touches no network, no Docker daemon, no `sudo`, and no host service
  manager.

## The `test` Surface And `test.dhall`

The `test` surface is owned by the root frame — the host orchestrator. It is a separate surface from
the chain that `project up` interprets: `project up` stands the persistent stack up, and `test run`
drives the standardized test engine, which stands that same deploy chain up under a generated config.
The surface is two subcommands:

- `test init` writes the sibling `<project>.test.dhall` and needs **no** pre-existing `<project>.dhall`.
  `<project>.test.dhall` is a thin override — the suite vocabulary, the config variants the matrix
  declares, per-suite budgets, and any fixtures the matrix needs — separate from the deploy parameters in
  `<project>.dhall`. The harness later turns each variant into a full run config functionally via the
  project-owned `psTestConfig` (which reuses the same value-free `psInit` builder as `project init`), so
  `test init` does not depend on a production config already existing.
- `test run <suite>` runs the single named suite over the standardized engine and prints its report
  card; `test run all` runs every suite, with `all` reserved by the verb (a project may not name a
  suite `all`). Both require a sibling `<project>.test.dhall`: `test run` fails fast when it is missing
  (directing you to run `test init` first), and an unknown selector fails fast listing the valid suite
  names and `all`. Production state is protected by the suite's two safety preconditions — it refuses if
  a config already exists at the executable sibling or if a production cluster is already running — not
  by an off-root-frame gate.

Under the hood each suite drives `runMatrix :: Seams env -> [Case] -> IO Report` over that suite's
case matrix. A project supplies its `Case`s and `Seams` as a non-empty `TestSuite` through
`ProjectSpec` (in its `app/Main.hs`), so the cases run under `test run`, not a per-noun subcommand. The
bare core binary ships no suites, so a bare `test run all` prints `test report: 0/0 passed`.

The harness is the single L0 test engine: per case it runs `seamSetup` → `seamRun` → `seamTeardown`,
with teardown guaranteed via `finally` — bring-up now runs **inside** the `finally`, so teardown fires
even when `project up` bring-up fails (a body exception is recorded as `Fail`, never leaked, and teardown
still runs; the `TestSuite` teardown is an env-independent `IO ()`, and each variant is isolated so one
failure never aborts the rest; a chain failure *during* `project up` is guarded so `applyChain` runs the
same best-effort `project destroy` teardown at the root frame, and an external kill — still uncatchable —
is reconciled by the next `project up` idempotent reconcile), aggregates a `Report`, renders it with
`reportCard`, and exits non-zero when `allPassed` is false. The
driver, the self-created-only `.test_data` lifecycle (`withSelfCreatedTestData` over the flat
`testDataRoot`, `.test_data`), the mechanical never-touch-production guard (`guardTestDelete`), and
budget-slicing (`sliceBudget`) all live once in `HostBootstrap.Harness`. `oneShotSeams` realize the
`OneShot` container run, while `defaultSeams` is the trivial pass-through for the bare binary's empty
matrix; a chain-driven suite's cases assert against the shared already-up stack via the harness-built
`assertSeams` (its `seamSetup` returns that env and its `seamTeardown` is a no-op). The full
per-case loop, the seam-split, and budget-slicing are documented in
[../architecture/harness_workflow.md](../architecture/harness_workflow.md); the four run-models the
`Seams` realize are in [../architecture/run_models.md](../architecture/run_models.md).

The `test` surface runs through the **project binary**, against the runtime — distinct from the
`check-code` verb, which is the fail-fast image-build gate over source shape (see
[code_check_doctrine.md](code_check_doctrine.md)).

## The Harness Drives The Chain, It Is Not A Parallel Chain

The harness **drives the real `project up`** rather than re-expressing bring-up. It is the **one**
representation of the test path because it *is* the deploy chain, run under a generated config. A suite may
declare **more than one config variant**; the harness stands each variant up, asserts, and tears it down in
turn. Per variant it **generates** the run's `<project>.dhall` functionally via the project-owned
`psTestConfig` (reusing the same `psInit` builder as `project init` — never shelling the CLI), runs
`project up` over the project's own chain (the full 9-step chain first provisions the VM and builds the
binary and image; its in-container persistent-stack segment is
`deploy-kind` → `deploy-registry` → `push-image` → `deploy-chart` → `expose-port`), runs the case assertions
in the frame appropriate to each (reusing the self-reference lift — e.g. a Playwright assertion as a
container on the VM host network in the VM frame, outside the cluster), and tears the stack down with
`project destroy` before moving to the next variant. The demo runs **two** variants — `"Hello, world!"`
then `"Hello, Universe!"` — with a full teardown and spin-up between, so the `message` field's whole
flow is exercised twice. There is no separate `seamSetup` that stands a cluster up a second way, so the
test and deploy resource models cannot drift.

Two **hard fail-fast safety preconditions** run before any test: the harness refuses if a config already
exists at the executable-sibling `siblingProjectConfigPath` (the `.build/<project>.dhall` it is about to
write, not the project root) so it never overwrites a production config, or if a production cluster is
running (never touch production state). Durable test storage is `.test_data` (never `.data`); teardown
deletes only the generated config and the `.test_data` the harness created this run, while keeping the
authored `test.dhall`. The canonical model — the lift chain as the project, the
recursive interpreter, and the harness as a driver of that chain — lives in
[../architecture/composition_methodology.md](../architecture/composition_methodology.md); this document
defers to it rather than re-deriving it.

## hostbootstrap-core (Haskell)

The Haskell library is tested as part of the project's canonical `check-code` and test targets,
built against the warm Cabal store. Coverage centres on pure values and command builders so the
suite stays hermetic:

- **Host-tool resolution** — the closed `HostTool` enumeration resolves to absolute paths; tests
  assert resolution and the fail-fast behaviour when a tool is absent.
- **Substrate detection** — `apple-silicon` / `linux-cpu` / `linux-gpu` / `windows-cpu` / `windows-gpu`
  classification from recorded host facts.
- **`ensure` reconcilers** — each reconciler's host-applicability predicate and the command tuples
  its reconcile action would emit, asserted without running Docker, Colima, Homebrew, or Ghc. A
  reconciler invoked for the wrong host is tested to fail fast with a non-zero exit. See
  [ensure_reconcilers.md](ensure_reconcilers.md).
- **Project-local Dhall config** — decoding/generating `<project>.dhall` and `<project>.test.dhall`,
  including project settings, runtime context authority, the suite vocabulary, the per-variant config the
  harness renders via `psTestConfig`, the demo's project-extended `message` field, and rejection of
  malformed values (every field mandatory, strict decode). See [schema.md](schema.md).
- **Cluster lifecycle** — kind/Helm command sequences and the never-delete-`.data` invariant. See
  [cluster_lifecycle.md](cluster_lifecycle.md).
- **Harness driver** — `HarnessSpec` asserts the per-case profile/path derivation, that teardown runs
  on a failing case body, that `guardTestDelete` rejects a non-prefixed name, and that `sliceBudget`
  keeps the concurrent slices within budget (with an indivisible case running at concurrency 1). The
  Playwright `e2e-tabs` spec is **polymorphic**: it reads `EXPECTED_MESSAGE` from the environment and
  asserts whichever `message` the active deployment set into its `#message` element, so the same spec
  validates both demo variants.
- **Documentation validator** — `HostBootstrap.DocValidator` exercised by `DocValidatorSpec`,
  asserting required metadata lines, broad-doctrine structure, relative-link resolution, and the
  phase-plan `## Documentation Requirements` retention.

These tests assert pure values and command builders directly — for example the pure arg-builders
that emit Docker and Colima command tuples and the reconcilers' applicability predicates — so they
verify the exact commands without executing them or driving the optparse command tree.

## Thin Python bootstrapper

The Python layer is small and so is its suite. It covers only the pre-binary bootstrapping steps the
Python layer owns: asserting the fail-fast host minimums (see [prerequisites.md](prerequisites.md)),
ensuring the host build toolchain, building the project binary host-native into `./.build/`, and
exec'ing it. Tests are hermetic — host detection and process invocation are stubbed or recorded. The
process-touching paths are exercised through a recorded-runner fixture (`tests/conftest.py`)
that replaces the process runner with an argv recorder, so they assert the exact commands without
executing them. The canonical Python code-check (formatter, linter, strict type-check) runs as part
of the base self-check (see [code_check_doctrine.md](code_check_doctrine.md)).

The enforced 100% coverage gate (`fail_under = 100`) covers the Python layer only and is statement
(line) coverage, not branch coverage. The Haskell `hostbootstrap-core` core has no coverage gate.

## Documentation validator

The mechanical documentation validator is a `hostbootstrap-core` quality gate.
`HostBootstrap.DocValidator` is wired into the tasty suite as `DocValidatorSpec` and
runs through `cabal test` by default; it verifies required metadata lines, broad-doctrine structure,
governed root-document metadata, relative-link resolution, and the phase-plan
`## Documentation Requirements` retention. Documentation conformance is therefore enforced
mechanically rather than by manual review against the documentation standard.

## What runs by default

The default unit-test run is hermetic and fast: no network, no Docker daemon, no `sudo`, no host
service manager. Tests that genuinely need a provisioned tool (a real `dhall` decode against fixtures,
a running Docker daemon) are marked and skipped when the dependency is absent. hostbootstrap does not
write launchd/systemd unit files and does not configure restart-after-reboot behavior, so there are
no unit-file rendering tests or real service-manager integration tests.

## Current Status

`DEVELOPMENT_PLAN/` is the implementation-status authority for this command surface.

- The standardized harness (`runMatrix` + `Seams`, the per-variant teardown/spin-up, the delete-guard,
  budget-slicing, and the report card) runs through `cabal test`. The fixed core tree is `project`,
  `test`, `service`, `context`, and `check-code` — the binary carries no per-project verbs; the demo
  contributes its `Web` service variant and its VM/provider IO as chain steps. The Python bootstrapper
  suite and the `HostBootstrap.DocValidator` gate run as part of their respective code-check and test targets.
- The `test init` / `test run <suite>|all` split is a root-frame surface backed by a sibling
  `<project>.test.dhall`. `test run all` **drives the real `project up`** under a generated config —
  one full up → assert → `project destroy` per declared config variant — asserts the live stack, and
  tears it down between variants, reusing the chain rather than standing up a separate per-case cluster.
  The recursive `project init|up|down|destroy` command interprets the `[Step]` chain
  across the composed frame stack: on Incus/Linux a single `project up` stands up the cordoned kind
  cluster, the in-cluster registry (NodePort 30500), the project image pushed to that
  registry, and the web chart pod serving HTTP 200 at `localhost:30080`; `project down` /
  `project destroy` tear it down with host `.data` preserved.

Implemented under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md), `test init`
writes `test.dhall` (a thin override) WITHOUT requiring a pre-existing `<project>.dhall`. For each config
variant the suite declares, `test run` GENERATES that variant's `<project>.dhall` via the project-owned
`psTestConfig` (reusing `psInit`), checks the fail-fast existence precondition at the executable sibling
`siblingProjectConfigPath` (`.build/<project>.dhall`, not the project root), drives the real `project up`,
asserts the live stack — with the Playwright spec reading `EXPECTED_MESSAGE` to assert whichever `message`
the variant set — runs `project destroy`, and finally deletes the generated `<project>.dhall` plus the
`.test_data` it created this run while keeping the authored `test.dhall`. The demo declares two variants
(`"Hello, world!"`, `"Hello, Universe!"`). See
the [generic_project_model.md](../architecture/generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).
