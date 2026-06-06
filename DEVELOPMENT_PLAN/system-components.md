# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative inventory of every component the host-management layer produces or
> consumes — `hostbootstrap-core` module surfaces, the `ensure` reconcilers and their host
> applicability, the skeletal `hostbootstrap.dhall` schema, the thin Python bootstrapper surface,
> the base image and warm Cabal store, and the optparse command tree projects extend.

> Note: items below describe the **target** component inventory. The repository currently ships the
> pure-Python CLI; rows marked Implemented `no` are planned surfaces the inversion delivers. The
> pure-Python surfaces being removed are tracked in
> [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). This repository does not use
> `.github/` workflows or GitHub Actions as a validation surface; see [README.md](README.md) for
> per-phase status.

## hostbootstrap-core Haskell module surface

The library lives under the `HostBootstrap.*` namespace. The module names below are the target
surface; the column records whether the module exists yet.

| Module | Phase | Implemented | Purpose |
|--------|-------|-------------|---------|
| `HostBootstrap.CLI` | 1 | no | `runHostBootstrapCLI progName projectCommands`; composable optparse entrypoint |
| `HostBootstrap.HostTool` | 2 | no | closed `HostTool` enumeration; absolute-path resolution |
| `HostBootstrap.HostConfig` | 2 | no | typed host configuration (lifted from infernix) |
| `HostBootstrap.HostPrereqs` | 2 | no | fail-fast host minimum checks |
| `HostBootstrap.Substrate` | 2 | no | substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) |
| `HostBootstrap.Ensure` | 3 | no | the `Reconciler` value type and the `ensure` subcommand wiring |
| `HostBootstrap.Ensure.Docker` | 3 | no | `ensure docker` reconciler |
| `HostBootstrap.Ensure.Colima` | 3 | no | `ensure colima` reconciler |
| `HostBootstrap.Ensure.Cuda` | 3 | no | `ensure cuda` reconciler |
| `HostBootstrap.Ensure.Homebrew` | 3 | no | `ensure homebrew` reconciler |
| `HostBootstrap.Ensure.Ghc` | 3 | no | `ensure ghc` reconciler |
| `HostBootstrap.Ensure.Tart` | 3 | no | `ensure tart` reconciler |
| `HostBootstrap.Config.Schema` | 4 | no | skeletal `hostbootstrap.dhall` schema + in-process decoder |
| `HostBootstrap.Command` | 4 | no | the core command tree projects extend |
| `HostBootstrap.Cluster.Lifecycle` | 5 | no | kind/Helm cluster up/down/delete semantics |
| `HostBootstrap.Cluster.Cordon` | 5 | no | resource-budget verification and cordoning |

`HostBootstrap.HostTool`, `HostBootstrap.HostConfig`, and `HostBootstrap.HostPrereqs` are lifted from
[`infernix`](https://github.com/Tuee22/infernix), which is the source of the host trio.

## Host-tool resolution

External tools resolve through a closed `HostTool` enumeration to absolute paths
(`HostBootstrap.HostTool`, Phase 2). No library or project code calls `proc "<bare-command-name>"`
that resolves through `$PATH`; every invocation reads an absolute path from typed host configuration.
See [development_plan_standards.md § K](development_plan_standards.md).

## Ensure reconcilers and host applicability

Each host dependency is an idempotent `ensure` reconciler: a host-applicability predicate plus a
reconcile action, exposed as an optparse subcommand. A reconciler run on the wrong host fails fast
with a one-line diagnostic and a non-zero exit. See
[development_plan_standards.md § L](development_plan_standards.md).

| Subcommand | Module | Phase | Applicable hosts | On wrong host |
|------------|--------|-------|------------------|---------------|
| `ensure docker` | `HostBootstrap.Ensure.Docker` | 3 | all substrates | n/a (universal) |
| `ensure colima` | `HostBootstrap.Ensure.Colima` | 3 | `apple-silicon` | fail fast, non-zero |
| `ensure cuda` | `HostBootstrap.Ensure.Cuda` | 3 | `linux-gpu` | fail fast, non-zero |
| `ensure homebrew` | `HostBootstrap.Ensure.Homebrew` | 3 | `apple-silicon` | fail fast, non-zero |
| `ensure ghc` | `HostBootstrap.Ensure.Ghc` | 3 | `apple-silicon` (host-native build path) | fail fast, non-zero |
| `ensure tart` | `HostBootstrap.Ensure.Tart` | 3 | `apple-silicon` (build-only) | fail fast, non-zero |

## Skeletal hostbootstrap.dhall schema

The skeletal `hostbootstrap.dhall` is the one config tier the Python bootstrapper reads; it is
identical in shape across projects. It carries only the fields Python needs before any project
binary exists:

| Field | Type | Read by |
|-------|------|---------|
| `project` | `Text` | Python bootstrapper + project binary |
| `dockerfile` | `Text` | Python bootstrapper |
| `resources` | `{ cpu : Natural, memory : Text, storage : Text }` | Python bootstrapper + project binary |

The resource budget is the single field both the Python layer and the project binary consume (see
[development_plan_standards.md § O](development_plan_standards.md)). The rich project-level Dhall
(runtime roles + cluster-bootstrap instructions) and per-case test Dhall are **generated by the
project binary**, which also emits its own schema; `hostbootstrap-core` owns only the skeletal-schema
decoder (see [development_plan_standards.md § Q](development_plan_standards.md)). The decoder is
in-process Haskell (`HostBootstrap.Config.Schema`, Phase 4); the current shelled `dhall-to-json`
path is removed.

## Thin Python bootstrapper surface

The Python bootstrapper does only what must run before any project binary exists (see
[development_plan_standards.md § M](development_plan_standards.md)):

| Step | Responsibility |
|------|----------------|
| 1 | assert the fail-fast host minimums |
| 2 | ensure Docker (provision the per-project Colima VM on Apple, sized to the budget) |
| 3 | build the project container (the `check-code` quality gate) |
| 4 | copy the built binary to `./.build/` |
| 5 | ensure host runtimes and exec the binary |

All other host-management logic lives in `hostbootstrap-core`. New host logic defaults to Haskell; a
Python addition must be justified by the pre-binary bootstrapping constraint.

## Build-twice / copy-out model

Every project binary is produced through Docker so the only universal host dependency is Docker (see
[development_plan_standards.md § N](development_plan_standards.md)).

| Substrate | Build location | Run location | Notes |
|-----------|----------------|--------------|-------|
| `linux-cpu`, `linux-gpu` | in the project container (`FROM` base) | host (shared glibc family) | binary copied to `./.build/` |
| `apple-silicon` | host-native (Python ensures host GHC via Homebrew) | host | a Linux ELF cannot exec on macOS |
| Tart (Apple, build-only) | Tart VM (Swift/Metal artifacts) | host | no built binary ever runs inside the Tart VM |

A `./.build/<binary>` is always present on the host. The container image is built on every substrate
— both for containerized workflows and as the mandatory code-check quality gate.

## Resource budget and cordoning

`hostbootstrap` verifies the host has the spare budget declared in `resources` and cordons it: on
Apple by sizing a dedicated per-project Colima VM, on Linux by applying kind node resource limits.
The cluster lifecycle never deletes host `.data`. The production-vs-test cluster profile distinction
selects fixed names / `.data` paths for production and per-case isolated paths for the test profile.
See `HostBootstrap.Cluster.Cordon` and `HostBootstrap.Cluster.Lifecycle` (Phase 5).

## Base image and warm Cabal store

The base image bakes the skeletal `hostbootstrap` binary (the core command tree with no project
commands) and warms the `hostbootstrap-core` dependencies into the frozen Cabal store.

| Component | Provides |
|-----------|----------|
| skeletal `hostbootstrap` binary | the core command tree, exec-ready before any project build |
| warm Cabal store + `cabal.project.freeze` | `hostbootstrap-core` deps prebuilt for derived project builds |
| GHC toolchain pinned to the core | matches `hostbootstrap-core`'s GHC pin |
| `ormolu`/`fourmolu` + `hlint` | the static quality-gate formatters/linters (pinned) |
| kube tools (`kubectl`, `helm`, `kind`) | cluster-lifecycle dependencies |

The base image continues to publish `basecontainer-<flavor>-<arch>` tags (CPU and CUDA flavors). See
`documents/engineering/base_image.md` and `documents/engineering/warm_store.md`.

## optparse command tree projects extend

`hostbootstrap-core` exposes its subcommands as a composable optparse value plus the generic
entrypoint `runHostBootstrapCLI progName projectCommands` (`HostBootstrap.CLI`, Phase 1; command
tree in `HostBootstrap.Command`, Phase 4). A project binary extends the core tree with its own
subcommands rather than re-implementing core verbs. The skeletal `hostbootstrap` binary baked into
the base image is the core tree with no project commands. See
[development_plan_standards.md § P](development_plan_standards.md).

| Core verb group | Phase | Source |
|-----------------|-------|--------|
| `ensure <tool>` | 3 | the `ensure` reconcilers |
| `config <...>` (skeletal decode) | 4 | `HostBootstrap.Config.Schema` |
| `cluster up/down/delete` | 5 | `HostBootstrap.Cluster.Lifecycle` |

## Update rule

When the host-management architecture changes (a new `HostBootstrap.*` module, a new `ensure`
reconciler, a skeletal-schema field, a base-image or warm-store change, a new core command-tree
verb), update this inventory in the same change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single source of
truth for the host-management component set.
