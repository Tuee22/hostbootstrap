# Testing

**Status**: Authoritative source
**Supersedes**: the pure-Python pytest/`test_all` suite description (spec/model/CLI-smoke layers)
**Referenced by**: [../README.md](../README.md), [code_check_doctrine.md](code_check_doctrine.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: Describe how hostbootstrap is tested across its Haskell `hostbootstrap-core` library
> and its thin Python bootstrapper, and where the planned documentation validator fits.

## TL;DR

- `hostbootstrap-core` (Haskell) carries the bulk of the test surface: host-tool resolution,
  substrate detection, the `ensure` reconcilers' pure decision logic, the skeletal-Dhall decoder,
  cluster-lifecycle semantics, and the optparse command tree.
- The thin Python bootstrapper carries a small, hermetic test surface for the pre-binary
  bootstrapping steps it owns.
- A mechanical documentation validator is a planned `hostbootstrap-core` quality-gate deliverable
  that runs through `check-code`.
- The default test run touches no network, no Docker daemon, no `sudo`, and no host service manager.

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
- **Skeletal-Dhall decoder** — decoding `hostbootstrap.dhall` into `project`, `dockerfile`, and the
  `resources` budget, plus rejection of malformed values. See [schema.md](schema.md).
- **Cluster lifecycle** — kind/Helm command sequences and the never-delete-`.data` invariant. See
  [cluster_lifecycle.md](cluster_lifecycle.md).
- **Command tree** — `runHostBootstrapCLI` dispatch and the composition of project subcommands onto
  the core tree.

The Docker- and Colima-touching paths are exercised through recorded-runner tests that replace the
process runner with an argv recorder, so they assert the exact commands without executing them.

## Thin Python bootstrapper

The Python layer is small and so is its suite. It covers only the pre-binary bootstrapping steps the
Python layer owns: asserting the fail-fast host minimums (see [prerequisites.md](prerequisites.md)),
ensuring the host build toolchain, building the project binary host-native into `./.build/`, and
exec'ing it. Tests are hermetic — host detection and process invocation are stubbed
or recorded, and the canonical Python code-check (formatter, linter, strict type-check) runs as part
of the base self-check (see [code_check_doctrine.md](code_check_doctrine.md)).

## Documentation validator (planned)

The mechanical documentation validator is a `hostbootstrap-core` quality-gate deliverable. Once it
lands it runs through `check-code` and verifies required metadata lines, broad-doctrine structure,
governed root-document metadata, relative-link resolution, and the phase-plan
`## Documentation Requirements` retention. Until it lands, documentation conformance is verified by
manual review against the documentation standard.

## What runs by default

The default test run is hermetic and fast: no network, no Docker daemon, no `sudo`, no host service
manager. Tests that genuinely need a provisioned tool (a real `dhall` decode against fixtures, a
running Docker daemon) are marked and skipped when the dependency is absent. hostbootstrap does not
write launchd/systemd unit files and does not configure restart-after-reboot behavior, so there are
no unit-file rendering tests or real service-manager integration tests.
