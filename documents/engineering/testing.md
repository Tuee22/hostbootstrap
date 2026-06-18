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
- The `test` surface is two root-gated subcommands: `test init` writes the project's `test.dhall`, and
  `test run <suite>|all` runs one named suite (or every suite via the reserved `all`).
- `hostbootstrap-core` (Haskell) carries the bulk of the unit-test surface: host-tool resolution,
  substrate detection, the `ensure` reconcilers' pure decision logic, the project-local Dhall config
  decoder/generator, cluster-lifecycle semantics, the harness driver, and the documentation validator.
- The thin Python bootstrapper carries a small, hermetic test surface for the pre-binary
  bootstrapping steps it owns.
- A mechanical documentation validator (`HostBootstrap.DocValidator`) is an implemented
  `hostbootstrap-core` quality-gate deliverable that runs through `cabal test`.
- The default unit-test run touches no network, no Docker daemon, no `sudo`, and no host service
  manager.

## The `test` Surface And `test.dhall`

The `test` surface is owned by the root frame — the host orchestrator. It is intentionally decoupled
from the chain that `project up` interprets: a chain stands the stack up, and `test run all` validates
that live stack from the root. The surface is two subcommands:

- `test init` requires an existing `<project>.dhall` (the root config the chain is a pure function of)
  and writes the sibling `test.dhall`. `test.dhall` carries test-specific configuration — the suite
  vocabulary, per-suite budgets, and any fixtures the matrix needs — separate from the deploy
  parameters in `<project>.dhall`. It fails fast unless invoked on the root frame with a project
  config present.
- `test run <suite>` runs the single named suite over the standardized engine and prints its report
  card; `test run all` runs every suite, with `all` reserved by the verb (a project may not name a
  suite `all`). Both are root-only: they fail fast, listing the valid suite names and `all`, when
  invoked off the root frame or without a `test.dhall`.

Under the hood each suite drives `runMatrix :: Seams env -> [Case] -> IO Report` over that suite's
case matrix. A project supplies its `Case`s and `Seams` as a non-empty `TestSuite` through
`ProjectSpec` (in its `app/Main.hs`), so the cases run under `test run`, not a per-noun subcommand. The
bare core binary ships no suites, so a bare `test run all` intentionally prints
`test report: 0/0 passed`.

The harness is the single L0 test engine: per case it runs `seamSetup` → `seamRun` → `seamTeardown`,
with teardown ALWAYS running via `finally`, records a body exception as `Fail` (never leaked),
aggregates a `Report`, renders it with `reportCard`, and exits non-zero when `allPassed` is false. The
driver, the isolated per-case profiles (cluster name `<project>-test-<case>`, data root
`./.test_data/<case>/`), the mechanical never-touch-production guard (`guardTestDelete`), and
budget-slicing (`sliceBudget`) all live once in `HostBootstrap.Harness`. The default `defaultSeams`
realize the `OneShot` container run; a cluster suite supplies kind/Helm seams instead. The full
per-case loop, the seam-split, and budget-slicing are documented in
[../architecture/harness_workflow.md](../architecture/harness_workflow.md); the four run-models the
`Seams` realize are in [../architecture/run_models.md](../architecture/run_models.md).

The `test` surface runs through the **project binary**, against the runtime — distinct from the
`check-code` verb, which is the fail-fast image-build gate over source shape (see
[code_check_doctrine.md](code_check_doctrine.md)).

## The Harness Is A Lift Target, Not A Parallel Chain

The harness is the **context-agnostic test engine**: its seams invoke reconcilers (e.g. cluster
bring-up) "locally", carrying no execution-context parameter and unaware of any enclosing frame. It is
therefore a **lift target**, lifted as a whole. A suite that needs its per-case cluster to come up in a
nested frame lifts the entire `test run` workflow there (through the selected VM provider and then
`docker run --rm <image> test run all`), and the cluster lands on that frame's Docker.

The `test run all` workflow is the **one** representation of the test path. Re-expressing cluster
bring-up / web-serve / e2e as a parallel chain of lifted operations alongside the harness would be a
redundant second representation — the chain `project up` interprets stands the stack up, and the test
surface validates it; the two are not two parallel test chains. The canonical model — the lift chain as
the project, the recursive interpreter, and why the harness is the single lift target — lives in
[../architecture/composition_methodology.md](../architecture/composition_methodology.md); this document
defers to it rather than re-deriving it.

## hostbootstrap-core (Haskell)

The Haskell library is tested as part of the project's canonical `check-code` and test targets,
built against the warm Cabal store. Coverage centres on pure values and command builders so the
suite stays hermetic:

- **Host-tool resolution** — the closed `HostTool` enumeration resolves to absolute paths; tests
  assert resolution and the fail-fast behaviour when a tool is absent.
- **Substrate detection** — `apple-silicon` / `linux-cpu` / `linux-gpu` classification from recorded
  host facts.
- **`ensure` reconcilers** — each reconciler's host-applicability predicate and the command tuples
  its reconcile action would emit, asserted without running Docker, Colima, Homebrew, or Tart. A
  reconciler invoked for the wrong host is tested to fail fast with a non-zero exit. See
  [ensure_reconcilers.md](ensure_reconcilers.md).
- **Project-local Dhall config** — decoding/generating `<project>.dhall` and `test.dhall`, including
  project settings, runtime context authority, the suite vocabulary, and rejection of malformed
  values. See [schema.md](schema.md).
- **Cluster lifecycle** — kind/Helm command sequences and the never-delete-`.data` invariant. See
  [cluster_lifecycle.md](cluster_lifecycle.md).
- **Harness driver** — `HarnessSpec` asserts the per-case profile/path derivation, that teardown runs
  on a failing case body, that `guardTestDelete` rejects a non-prefixed name, and that `sliceBudget`
  keeps the concurrent slices within budget (with an indivisible case running at concurrency 1).
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

The mechanical documentation validator is an implemented `hostbootstrap-core` quality-gate
deliverable. `HostBootstrap.DocValidator` is wired into the tasty suite as `DocValidatorSpec` and
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

The command surface described here is shipped and real-run-validated end-to-end;
`DEVELOPMENT_PLAN/` remains the implementation-status authority.

- **Shipped and validated.** The standardized harness (`runMatrix` + `Seams`, the per-case isolation,
  the delete-guard, budget-slicing, and the report card) ships and runs through `cabal test`. The
  `ensure`, `context`, `project`, `test`, and `check-code` verbs are the core top-level command tree the
  binary carries now; the demo retains only its `web` verb and its `vm` / `incus` debug-hatch verbs. The
  Python bootstrapper suite and the `HostBootstrap.DocValidator` gate are both implemented and green.
- **Validated end-to-end.** The `test init` / `test run <suite>|all` split, gated to the root frame and
  backed by a sibling `test.dhall`, is the shipped surface — decoupled from the chain so `test run all`
  validates the live stack that the recursive `project up` interpreter stands up. The recursive
  `project init|up|down|destroy` command and the `[Step]` chain it interprets are real-run-validated
  end-to-end: a single `project up` on Incus/Linux stood up the cordoned kind cluster, the full 8-pod
  production Harbor (NodePort 30500), the 20GB project image pushed to the in-cluster registry, and the
  web chart pod serving HTTP 200 at `localhost:30080`, then `project down` / `project destroy` tore it
  down with host `.data` preserved.
