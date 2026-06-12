# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](composition_methodology.md), [python_haskell_boundary](python_haskell_boundary.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its module surface and the
> command-tree extension contract project binaries use to build on top of it.

## TL;DR

- `hostbootstrap-core` is the Haskell library that owns all host-management logic: host-tool
  resolution, substrate detection, `ensure` reconcilers, the static-base-Dhall decoder, and
  cluster-lifecycle semantics.
- It exposes its subcommands as a composable `optparse-applicative` value plus a generic entrypoint,
  `runHostBootstrapCLI progName projectCommands`.
- Project binaries import the library through a pinned `source-repository-package` git dependency and
  extend the core command tree with their own subcommands.
- The bare `hostbootstrap` binary is the core tree with no project commands; it is built like any
  project binary (host-native), not baked into the base image.

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
| `HostBootstrap.Ensure.*` | One reconciler module per host dependency (`Docker`, `Colima`, `Cuda`, `Homebrew`, `Ghc`, `Tart`); each is an idempotent value with a host-applicability predicate and a reconcile action. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Config.Schema` | Decoder for the static-base `hostbootstrap.dhall` (`project`, `dockerfile`, `resources {cpu,memory,storage}`). Core owns only this decoder; rich schemas are project artifacts. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Cluster.Cordon` | Resource-budget verification and cordoning (per-project Colima VM on Apple, kind node limits on Linux). See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Lifecycle` | kind/Helm cluster up/down/delete semantics and the never-delete-`.data` invariant. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Lift` | The self-reference compositional lift: run a subcommand of the binary in a nested context (`Local`/`InVM`/`InContainer`) by invoking the binary again there. The pure argv fold is unit-tested; the IO seam reuses tool resolution. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Harness` | The standardized test engine — `runMatrix` over a project's `Seams` (`seamSetup`/`seamRun`/`seamTeardown`), the per-case isolation, the delete-guard, and budget-slicing. The harness is **context-agnostic**: its seams invoke reconcilers (e.g. `cluster up`) "locally", so the harness is a **lift target**, not a lift-aware component — there is no `LiftContext` inside it (a consumer lifts the whole `test all` workflow, never re-expressing it as a parallel chain). See [harness workflow](harness_workflow.md). |
| `HostBootstrap.Command` | The composable core command tree (`coreCommands`) merging the `ensure`, `config`, and `cluster` verbs. |
| `HostBootstrap.CLI` | `runHostBootstrapCLI`, the generic entrypoint that merges `coreCommands` with project commands. |
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
generic entrypoint:

```haskell
runHostBootstrapCLI :: String -> [Mod CommandFields (IO ())] -> IO ()
```

- `progName` is the program name used in help and diagnostics.
- `projectCommands` is the list of project-specific `command "..."` entries.
- The function merges `projectCommands` with the core subcommand value (`ensure …`, `cluster …`,
  `config …`) and runs the resulting parser.

A project binary extends the core tree rather than re-implementing core verbs. Its `Main.hs`
composes its own commands and hands them to the entrypoint:

```haskell
import HostBootstrap.CLI (runHostBootstrapCLI)

projectCommands :: [Mod CommandFields (IO ())]
projectCommands =
  [ command "config" (info configParser (progDesc "Emit the project schema and render config"))
  , command "test"   (info testParser   (progDesc "Run the project test harness"))
  ]

main :: IO ()
main = runHostBootstrapCLI "daemon-substrate" projectCommands
```

The bare `hostbootstrap` binary is the same entrypoint with no project commands (built like any
project binary, not baked into the base image):

```haskell
main :: IO ()
main = runHostBootstrapCLI "hostbootstrap" []
```

This guarantees that `ensure …`, `cluster …`, and `config …` behave identically whether invoked
through the bare binary or through any project binary; a project only adds verbs, it never
shadows or rewrites the core ones.

## Consumption

The library is consumed as a pinned `source-repository-package` git dependency in each project's
`cabal.project`, so every consumer builds against an exact commit. The base image warms
`hostbootstrap-core`'s dependencies into the frozen Cabal store so derived builds hit the warm store.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
