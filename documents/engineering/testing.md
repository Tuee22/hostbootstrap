# Testing

**Status**: Authoritative source
**Supersedes**: the pure-Python pytest/`test_all` suite description (spec/model/CLI-smoke layers)
**Referenced by**: [../README.md](../README.md), [code_check_doctrine.md](code_check_doctrine.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: Describe how hostbootstrap is tested across its Haskell `hostbootstrap-core` library
> and its thin Python bootstrapper, and where the documentation validator fits.

## TL;DR

- Every project's tests run through one standardized engine — `runMatrix` over a `Seams` record — and
  the inherited `test` verb prints its report card. The mechanics live once in
  `HostBootstrap.Harness`; the app supplies only its case matrix. See
  [../architecture/harness_workflow.md](../architecture/harness_workflow.md).
- `hostbootstrap-core` (Haskell) carries the bulk of the unit-test surface: host-tool resolution,
  substrate detection, the `ensure` reconcilers' pure decision logic, the static-base-Dhall decoder,
  cluster-lifecycle semantics, the harness driver, and the documentation validator.
- The thin Python bootstrapper carries a small, hermetic test surface for the pre-binary
  bootstrapping steps it owns.
- A mechanical documentation validator (`HostBootstrap.DocValidator`) is an implemented
  `hostbootstrap-core` quality-gate deliverable that runs through `cabal test`.
- The default test run touches no network, no Docker daemon, no `sudo`, and no host service manager.

## The Standardized Harness and the `test` Verb

Every `hostbootstrap` binary inherits a `test` verb from the core command tree. `<project> test all`
drives `runMatrix :: Seams env -> [Case] -> IO Report` over the project's **whole** case matrix and
prints the report card; `<project> test <case>` runs the single case with that id (an unknown id fails
fast, listing the valid ids and `all`). A project supplies its `Case`s and `Seams` as a `TestSuite`
threaded into the inherited `test` verb via `runHostBootstrapCLI` (its `app/Main.hs`), so the cases run
under `test`, not a per-noun subcommand. The bare core binary ships an empty matrix
(`emptySuite`), so `test all` prints `test report: 0/0 passed`. `all` is reserved by the verb, so a
project may not name a case `all`.

The harness is the single L0 test engine: per case it runs `seamSetup` → `seamRun` →
`seamTeardown`, with teardown ALWAYS running via `finally`, records a body exception as `Fail` (never
leaked), aggregates a `Report`, and renders it with `reportCard` / checks it with `allPassed`. The
driver, the isolated per-case profiles (cluster name `<project>-test-<case>`, data root
`./.test_data/<case>/`), the mechanical never-touch-production guard (`guardTestDelete`), and
budget-slicing (`sliceBudget`) all live once in `HostBootstrap.Harness`. The default `defaultSeams`
realize the `OneShot` container run; a cluster project supplies kind/Helm seams instead. The full
per-case loop, the seam-split, and budget-slicing are documented in
[../architecture/harness_workflow.md](../architecture/harness_workflow.md); the four run-models the
`Seams` realize are in [../architecture/run_models.md](../architecture/run_models.md).

The harness runs through the **project binary**, against the runtime — distinct from the `check-code`
verb, which is the fail-fast image-build gate over source shape (see
[code_check_doctrine.md](code_check_doctrine.md)).

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
- **Static-Base-Dhall decoder** — decoding `hostbootstrap.dhall` into `project`, `dockerfile`, and the
  `resources` budget, plus rejection of malformed values. See [schema.md](schema.md).
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

The default test run is hermetic and fast: no network, no Docker daemon, no `sudo`, no host service
manager. Tests that genuinely need a provisioned tool (a real `dhall` decode against fixtures, a
running Docker daemon) are marked and skipped when the dependency is absent. hostbootstrap does not
write launchd/systemd unit files and does not configure restart-after-reboot behavior, so there are
no unit-file rendering tests or real service-manager integration tests.
