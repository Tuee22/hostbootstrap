# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative inventory of every component the host-management layer produces or
> consumes — `hostbootstrap-core` module surfaces, the `ensure` reconcilers and their host
> applicability, the skeletal `hostbootstrap.dhall` schema, the thin Python bootstrapper surface,
> the base image and warm Cabal store, and the optparse command tree projects extend.

> Note: the inversion buildout (Phases 1–7) is implemented — the `HostBootstrap.*` modules below exist
> and the Python layer is the thin five-step bootstrapper — and `hostbootstrap-core` is consumable via
> `runHostBootstrapCLI`. The **global-architecture deltas** (Dhall generation, the applied cordon, the
> standardized harness, incus, the layered warm store, the demo) are scoped in Phases 8–13 and are **not
> yet implemented**; the rows below carry their owning phase and an Implemented column. The Python
> surfaces removed along the way are recorded in
> [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). This repository does not use
> `.github/` workflows or GitHub Actions as a validation surface; see [README.md](README.md) for
> per-phase status.

## hostbootstrap-core Haskell module surface

The library lives under the `HostBootstrap.*` namespace. The module names below are the target
surface; the column records whether the module exists yet.

| Module | Phase | Implemented | Purpose |
|--------|-------|-------------|---------|
| `HostBootstrap.CLI` | 1 | yes | `runHostBootstrapCLI progName projectCommands`; composable optparse entrypoint |
| `HostBootstrap.HostTool` | 2 | yes | closed `HostTool` enumeration; absolute-path resolution |
| `HostBootstrap.HostConfig` | 2 | yes | typed host configuration (lifted from infernix) |
| `HostBootstrap.HostPrereqs` | 2 | yes | fail-fast host minimum checks |
| `HostBootstrap.Substrate` | 2 | yes | substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) |
| `HostBootstrap.Ensure` | 3 | yes | the `Reconciler` value type and the `ensure` subcommand wiring |
| `HostBootstrap.Ensure.Docker` | 3 | yes | `ensure docker` reconciler |
| `HostBootstrap.Ensure.Colima` | 3 | yes | `ensure colima` reconciler |
| `HostBootstrap.Ensure.Cuda` | 3 | yes | `ensure cuda` reconciler |
| `HostBootstrap.Ensure.Homebrew` | 3 | yes | `ensure homebrew` reconciler |
| `HostBootstrap.Ensure.Ghc` | 3 | yes | `ensure ghc` reconciler |
| `HostBootstrap.Ensure.Tart` | 3 | yes | `ensure tart` reconciler |
| `HostBootstrap.Config.Schema` | 4 | yes | skeletal `hostbootstrap.dhall` schema + in-process decoder |
| `HostBootstrap.Command` | 4 | yes | the core command tree projects extend |
| `HostBootstrap.Cluster.Lifecycle` | 5 | yes | kind/Helm cluster up/down/delete semantics |
| `HostBootstrap.Cluster.Cordon` | 5, 9 | partial | budget verification + sizing args (yes); `fitsBudget` + the applied `docker update` cordon + the one canonical parser (Phase 9, no) |
| `HostBootstrap.DocValidator` | 0 | yes | mechanical documentation validator run through the code-check |
| `HostBootstrap.Dhall.Gen` | 8 | no | the Dhall-generation substrate + the `ConfigArtifact` registry |
| `HostBootstrap.Harness` | 10 | no | `runMatrix` + `Seams` + `guardTestDelete` + budget-slicing |
| `HostBootstrap.HostTarget` | 11 | no | `Local \| InVM` target dispatch (`runInTarget`) |
| `HostBootstrap.Incus` | 11 | no | incus VM lifecycle (`create`/`exec`/`reboot`/`destroy`, name-guarded) |
| `HostBootstrap.Ensure.Incus` | 11 | no | `ensure incus` install-and-verify reconciler |

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
| `ensure incus` | `HostBootstrap.Ensure.Incus` | 11 | `apple-silicon` **and** `linux-cpu`/`linux-gpu` (install-and-verify) | fail fast, non-zero |

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
decoder (see [development_plan_standards.md § Q](development_plan_standards.md)). The static-base tier is
read **pre-binary by the Python bootstrapper via the pinned `dhall-to-json`** (`dhall_tool.py`,
retained); the in-process Haskell decoder (`HostBootstrap.Config.Schema`, Phase 4) backs `config show`
after the binary exists. An anti-drift check keeps `Type.dhall` and the Python-side `package.dhall` the
same shape.

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

The base image warms the `hostbootstrap-core` dependencies into the frozen Cabal store. It bakes
**no** `hostbootstrap` binary: a Linux ELF cannot run on Apple silicon, so it could not be copied out
to every host. Every project builds its own binary host-native and in-container (the build-twice /
copy-out model), accelerated by the warm store.

| Component | Provides |
|-----------|----------|
| warm Cabal store, split `core.freeze` / `daemon.freeze` (Phase 12; generated in-image, never committed) | `core.freeze` warms base + `hostbootstrap-core` (imported by `mcts` and `daemon-substrate`); `daemon.freeze` warms the daemon-family deps (daemon apps only) |
| GHC toolchain pinned to the core | matches `hostbootstrap-core`'s GHC pin |
| `ormolu`/`fourmolu` + `hlint` | the static quality-gate formatters/linters (pinned) |
| kube tools (`kubectl`, `helm`, `kind`) | cluster-lifecycle dependencies |

The base image continues to publish `basecontainer-<flavor>-<arch>` tags (CPU and CUDA flavors). See
`documents/engineering/base_image.md` and `documents/engineering/warm_store.md`.

## optparse command tree projects extend

`hostbootstrap-core` exposes its subcommands as a composable optparse value plus the generic
entrypoint `runHostBootstrapCLI progName projectCommands` (`HostBootstrap.CLI`, Phase 1; command
tree in `HostBootstrap.Command`, Phase 4). A project binary extends the core tree with its own
subcommands rather than re-implementing core verbs. The skeletal `hostbootstrap` binary
(`hostbootstrap-core`'s own executable) is the core tree with no project commands, built like any
project binary rather than baked into the base image. See
[development_plan_standards.md § P](development_plan_standards.md).

| Core verb group | Phase | Source |
|-----------------|-------|--------|
| `ensure <tool>` (incl. `incus`) | 3, 11 | the `ensure` reconcilers |
| `config show` (static-base decode) | 4 | `HostBootstrap.Config.Schema` |
| `config schema` / `config render` | 8 | `HostBootstrap.Dhall.Gen` + the `ConfigArtifact` registry |
| `cluster up/down/delete/status` | 5, 9 | `HostBootstrap.Cluster.Lifecycle` |
| `test <suite>` | 10 | `HostBootstrap.Harness` (`runMatrix`) |
| `check-code` | 10 | project-defined body, the image-build gate |

## hostbootstrap-demo (worked consumer)

`hostbootstrap-demo` (Phase 13) is the self-contained worked consumer under `demo/` (own static-base
`hostbootstrap.dhall`, Haskell source, build path `demo/.build`). It extends `hostbootstrap-core` directly
(L0-direct) and exercises the full surface — `ensure incus`, the host-provider axis, `config schema`/
`render`, the standardized harness, the applied budget cordons, an idiomatic in-Dockerfile `check-code`
gate, a `purescript-bridge`/`spago` webservice and SPA, and Playwright e2e — centered on a from-zero
pristine-host bootstrap inside an incus VM. It supersedes `haskell/hostbootstrap-core/example/Main.hs`.

## Update rule

When the host-management architecture changes (a new `HostBootstrap.*` module, a new `ensure`
reconciler — including a host-provider like `incus`, a static-base-schema field, a base-image or
warm-store change — including a freeze-fragment split, a new core command-tree verb, a new run-model, or
the worked-consumer demo), update this inventory in the same change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single source of
truth for the host-management component set.
