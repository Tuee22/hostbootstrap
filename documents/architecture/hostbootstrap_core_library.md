# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its module surface and the
> command-tree extension contract project binaries use to build on top of it.

## TL;DR

- `hostbootstrap-core` is the Haskell library that owns all host-management logic: host-tool
  resolution, substrate detection, `ensure` reconcilers, the skeletal-Dhall decoder, and
  cluster-lifecycle semantics.
- It exposes its subcommands as a composable `optparse-applicative` value plus a generic entrypoint,
  `runHostBootstrapCLI progName projectCommands`.
- Project binaries import the library through a pinned `source-repository-package` git dependency and
  extend the core command tree with their own subcommands.
- The skeletal `hostbootstrap` binary baked into the base image is the core tree with no project
  commands.

## Module Surface

The library namespace is `HostBootstrap.*`. The module set below is indicative of the surface
consumers depend on; it is the canonical inventory tracked in
[`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md).

| Module | Responsibility |
|--------|----------------|
| `HostBootstrap.HostTool` | Closed `HostTool` enumeration of external tools resolved to absolute paths; no `$PATH`-resolved bare-command invocation. |
| `HostBootstrap.HostConfig` | Typed host configuration: resolved tool paths, detected substrate, and the spare-resource view used for budgeting. |
| `HostBootstrap.Substrate` | Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) and host-applicability predicates. |
| `HostBootstrap.Ensure.*` | One reconciler module per host dependency (`Docker`, `Colima`, `Cuda`, `Homebrew`, `Ghc`, `Tart`); each is an idempotent value with a host-applicability predicate and a reconcile action. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Skeleton` | Decoder for the skeletal `hostbootstrap.dhall` (`project`, `dockerfile`, `resources {cpu,memory,storage}`). Core owns only this decoder; rich schemas are project artifacts. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Cluster` | kind/Helm cluster-lifecycle semantics, the never-delete-`.data` invariant, and resource cordoning. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.CLI` | The composable `optparse-applicative` command tree and `runHostBootstrapCLI`. |

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

The skeletal `hostbootstrap` binary baked into the base image is the same entrypoint with no project
commands:

```haskell
main :: IO ()
main = runHostBootstrapCLI "hostbootstrap" []
```

This guarantees that `ensure …`, `cluster …`, and `config …` behave identically whether invoked
through the skeletal binary or through any project binary; a project only adds verbs, it never
shadows or rewrites the core ones.

## Consumption

The library is consumed as a pinned `source-repository-package` git dependency in each project's
`cabal.project`, so every consumer builds against an exact commit. The base image warms
`hostbootstrap-core`'s dependencies into the frozen Cabal store so derived builds hit the warm store.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
