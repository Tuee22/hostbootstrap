# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](composition_methodology.md), [binary_context_config](binary_context_config.md), [python_haskell_boundary](python_haskell_boundary.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its module surface and the
> command-tree extension contract project binaries use to build on top of it.

## TL;DR

- `hostbootstrap-core` is the Haskell library that owns all host-management logic: host-tool
  resolution, substrate detection, `ensure` reconcilers, cluster-lifecycle semantics, and the
  binary-context validation and command-gating substrate.
- It exposes its subcommands as a composable `optparse-applicative` value plus a generic project
  entrypoint, `runHostBootstrapCLI progName projectSpec`.
- Project binaries import the library through a pinned `source-repository-package` git dependency and
  extend the core command tree with named project commands, a non-empty test suite, a code-check action,
  and a schema artifact delta.
- The bare `hostbootstrap` binary uses the separate `runBareHostBootstrapCLI`; it is the only binary with
  no project commands/checks/artifacts and an empty test matrix.

## Current Status

The implemented module surface includes the project-local `HostBootstrap.Config.Schema` decoder/encoder,
binary-owned `config init` and child-projection helpers, and the command gate that reads the context
section inside sibling `<project>.dhall`. Phase 8 owns the generated-config machinery; Phase 15 owns the
runtime gate and local-config lookup rule.

## Module Surface

The library namespace is `HostBootstrap.*`. The module set below is indicative of the surface
consumers depend on; it is the canonical inventory tracked in
[`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md).

| Module | Responsibility |
|--------|----------------|
| `HostBootstrap.HostTool` | Closed `HostTool` enumeration of external tools resolved to absolute paths; no `$PATH`-resolved bare-command invocation. |
| `HostBootstrap.HostConfig` | Typed host configuration: resolved tool paths, detected substrate, and the spare-resource view used for budgeting. |
| `HostBootstrap.HostPrereqs` | Fail-fast host-minimum checks (the pre-binary subset the thin bootstrapper reclaims). |
| `HostBootstrap.Substrate` | Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) and host-applicability predicates. |
| `HostBootstrap.Ensure` | The `Reconciler` value type and the generic `ensure <tool>` subcommand dispatcher. |
| `HostBootstrap.Ensure.*` | One reconciler module per host dependency (`Docker`, `Colima`, `Lima`, `Cuda`, `Homebrew`, `Ghc`, `Tart`); each is an idempotent value with a host-applicability predicate and a reconcile action. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Config.Schema` | Owner for project-local `<project>.dhall` schema/default surfaces, sibling lookup, child projections, and service/daemon config snapshot log metadata. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Context` | Binary-context substrate inside `<project>.dhall`: discover the sibling path, construct host/VM/container/service contexts, validate project/binary/capability/command requirements, and provide the command-gating API used by normal dispatch. See [binary_context_config](binary_context_config.md). |
| `HostBootstrap.Cluster.Cordon` | Resource-budget verification and cordoning (Colima/Lima VM sizing args and kind node limits). See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Lifecycle` | kind/Helm cluster up/down/delete semantics and the never-delete-`.data` invariant. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Lima` | Lima VM lifecycle argv builders for the Apple Silicon pristine demo VM (`start`, `shell`, `copy`, guarded `delete`). |
| `HostBootstrap.Lift` | The self-reference compositional lift: run a subcommand of the binary in a nested context (`Local`/provider VM/`InContainer`) by invoking the binary again there. The pure argv fold is unit-tested; the IO seam reuses tool resolution. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Harness` | The standardized test engine — `runMatrix` over a project's `Seams` (`seamSetup`/`seamRun`/`seamTeardown`), the per-case isolation, the delete-guard, and budget-slicing. The harness is **context-agnostic**: its seams invoke reconcilers (e.g. `cluster up`) "locally", so the harness is a **lift target**, not a lift-aware component — there is no `LiftContext` inside it (a consumer lifts the whole `test all` workflow, never re-expressing it as a parallel chain). See [harness workflow](harness_workflow.md). |
| `HostBootstrap.Command` | The composable core command tree (`coreCommands`) merging the `ensure`, `config`, and `cluster` verbs. |
| `HostBootstrap.CLI` | `ProjectSpec`, `ProjectCommand`, `runHostBootstrapCLI`, and `runBareHostBootstrapCLI`; the entrypoint validates project extension points before merging them with `coreCommands`. |
| `HostBootstrap.DocValidator` | The mechanical documentation validator run through the code-check. See [documentation_standards](../documentation_standards.md). |

## Host-Tool Resolution And Substrate Ownership

External tools are resolved through the closed `HostTool` enumeration (`HostBootstrap.HostTool`) to
absolute paths. The `AbsExe` newtype makes a bare command name unrepresentable as a resolved tool —
its smart constructor rejects any non-absolute path — so no library or project code invokes a
`$PATH`-resolved bare command (see [development_plan_standards.md § K](../../DEVELOPMENT_PLAN/development_plan_standards.md)).
`HostBootstrap.HostConfig` is the typed configuration that pairs the detected substrate with the
resolved tool paths the reconcilers read.

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) is owned by
`HostBootstrap.Substrate`; its classification core is pure (`classify`, `parseDockerArch`) with a thin
IO wrapper for the platform reads and the NVIDIA probe. `HostBootstrap.HostPrereqs` carries the
fail-fast host minimums, dispatched by substrate, each resolving its tools through the typed
configuration. See [prerequisites](../engineering/prerequisites.md).

## Command-Tree Extension Contract

`HostBootstrap.CLI` exposes the core subcommands as a composable `optparse-applicative` value and a
generic project entrypoint:

```haskell
projectCommand :: String -> ParserInfo (IO ()) -> ProjectCommand
projectSpec :: [ProjectCommand] -> TestSuite -> IO () -> [ConfigArtifact] -> ProjectSpec
runHostBootstrapCLI :: String -> ProjectSpec -> IO ()
runBareHostBootstrapCLI :: String -> IO ()
```

- `progName` is the program name used in help and diagnostics.
- `ProjectCommand` carries the top-level command name together with its parser, so the entrypoint can
  reject duplicate project names and core-command shadowing before parsing.
- `ProjectSpec` carries the project command delta, the non-empty `TestSuite` threaded into the inherited
  `test` verb, the project-defined `check-code` action, and the project `ConfigArtifact` delta. It is the
  functional-programming boundary: absence is represented by a different entrypoint (`runBareHostBootstrapCLI`),
  not by a silent project default.
- `runHostBootstrapCLI` validates the spec, merges it with the core subcommand value (`ensure …`,
  `cluster …`, `config …`, `test`, `check-code`), and runs the resulting parser. Normal core commands load
  the sibling binary-context file before dispatch and refuse commands that do not match the declared context.

A project binary extends the core tree rather than re-implementing core verbs. Its `Main.hs`
composes its own commands and hands them to the entrypoint:

```haskell
import HostBootstrap.CLI (projectCommand, projectSpec, runHostBootstrapCLI)

projectCommands :: [ProjectCommand]
projectCommands =
  [ projectCommand "web" (info webParser (progDesc "Serve and build the web UI"))
  ]

main :: IO ()
main =
  runHostBootstrapCLI
    "daemon-substrate"
    (projectSpec projectCommands daemonSuite daemonCheckCode daemonArtifacts)
```

The bare `hostbootstrap` binary is explicit, not a project pretending to have empty hooks:

```haskell
main :: IO ()
main = runBareHostBootstrapCLI "hostbootstrap"
```

This guarantees that `ensure …`, `cluster …`, and `config …` behave identically whether invoked
through the bare binary or through any project binary; a project only adds verbs, it never
shadows or rewrites the core ones. A shadow attempt is rejected before command dispatch.

The command tree includes ungated config surfaces such as `config path`, `config schema`, `config init`,
`config show FILE`, and `config render`. Those bootstrap/inspection commands are allowed before a
sibling config exists; `config render` prints static typed registry examples, not child runtime
authority, and `--artifact NAME` fails fast when `NAME` is not in the in-scope registry. Normal commands
and child-config creation during VM/container/service handoff fail fast when `<project>.dhall` is missing
or incompatible. Project-specific commands use the same `HostBootstrap.Context` gate to declare their
command class. The inherited `test` verb prints the report and exits non-zero when any selected case fails.

## Consumption

The library is consumed as a pinned `source-repository-package` git dependency in each project's
`cabal.project`, so every consumer builds against an exact commit. The base image warms
`hostbootstrap-core`'s dependencies into the frozen Cabal store so derived builds hit the warm store.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
