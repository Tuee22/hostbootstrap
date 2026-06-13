# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative inventory of every component the host-management layer produces or
> consumes — `hostbootstrap-core` module surfaces, the `ensure` reconcilers and their host
> applicability, the static-base `hostbootstrap.dhall` schema, the runtime binary-context config, the
> thin Python bootstrapper surface, the base image and warm Cabal store, and the optparse command tree
> projects extend.

> Note: the inversion buildout (Phases 1–7) is implemented — the `HostBootstrap.*` modules below exist,
> the Python CLI is the thin `doctor` / `build` / `run` / `base` pre-binary bootstrapper (converged on the
> §M/§N boundary), and `hostbootstrap-core` is consumable via `runHostBootstrapCLI`. The
> **global-architecture deltas** are implemented and unit-tested — Dhall generation (Phase 8),
> the applied cordon (Phase 9), the standardized harness (Phase 10), and the incus host-provider
> (Phase 11) are all landed; the layered warm store (Phase 12) and the worked demo (Phase 13) are
> implemented and **exercised in real runs** (incus VMs, the pristine 3-build bootstrap, the harness
> cluster lifecycle, the web/Playwright stack). **Phases 0–15 are `Done`.** The **single-representation
> doctrine** ([development_plan_standards.md § W](development_plan_standards.md) — one operation, one
> representation; the standardized test harness is the one representation, **lifted** into the project
> container in the VM via `incus exec <vm> -- docker run --rm <image> test all`, with no parallel deploy
> chain alongside it) is **implemented and live-validated**: Phase-13 Sprint 13.12 collapsed the demo deploy
> to the single lift sequence, and the literal `demo deploy` apply runs `3/3` with the kind cluster on the
> **VM's** Docker (poller-confirmed in the VM, none on metal), guarded teardown, no leftovers. The earlier
> metal-host in-container runs were a dev shortcut, superseded by the in-VM lift. The operator-scale
> real runs (multi-arch published base tags, the full Harbor deployment, the multi-GB image push) follow
> the § Validation Policy standard. The rows below carry their owning phase and an
> Implemented column. The sibling `project-binary-context-config.dhall` runtime authority and command
> gating for host, VM, container, and service copies of a binary are implemented and validated. The
> Python surfaces removed along the way are recorded in
> [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). This repository does not use
> `.github/` workflows or GitHub Actions as a validation surface; see [README.md](README.md) for
> per-phase status.

## hostbootstrap-core Haskell module surface

The library lives under the `HostBootstrap.*` namespace. The module names below are the target
surface; the column records whether the module exists yet.

| Module | Phase | Implemented | Purpose |
|--------|-------|-------------|---------|
| `HostBootstrap.CLI` | 1 | yes | `runHostBootstrapCLI progName projectCommands testSuite`; composable optparse entrypoint |
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
| `HostBootstrap.Config.Schema` | 4 | yes | static-base `hostbootstrap.dhall` schema + in-process decoder |
| `HostBootstrap.Context` | 15.1, 15.3, 15.4 | yes | binary-context type/decoder/renderer, sibling-file discovery, host/VM/container/service constructors, validation, exit-code-1 failure, and command-gating API for `project-binary-context-config.dhall` |
| `HostBootstrap.Command` | 4, 15.4 | yes | the core command tree projects extend; normal core commands gate through the sibling binary context |
| `HostBootstrap.Cluster.Lifecycle` | 5 | yes | kind/Helm cluster up/down/delete semantics |
| `HostBootstrap.Cluster.Cordon` | 5, 9 | yes | the one canonical `parseQuantity`, budget verification, the full `colima`/kind-node argv builders, `verifyBudget`/`fitsBudget`, and the applied `docker update` kind-node cordon |
| `HostBootstrap.DocValidator` | 0 | yes | mechanical documentation validator run through the code-check |
| `HostBootstrap.Config.Vocab` | 8 | yes | Haskell mirrors of the `Core.dhall` vocabulary record types (reflected for schema-gen) |
| `HostBootstrap.Dhall.Gen` | 8 | yes | the Dhall-generation substrate + the `ConfigArtifact` registry (reflected schema + render) |
| `HostBootstrap.Harness` | 10 | yes | `runMatrix` + `Seams` + the `TestSuite` hook (`runSuiteSelection`/`emptySuite`, threaded into the inherited `test` verb) + `guardTestDelete` + `sliceBudget` + `selectRunModel` (the four run-models) + the L0 OneShot seam (`oneShotRunArgs` argv + `oneShotSeams` IO seam) |
| `HostBootstrap.HostTarget` | 11 | yes | `Local \| InVM` target dispatch (`runInTarget`) + the reboot-to-ready loop (the tool-level lift) |
| `HostBootstrap.Lift` | 11 | yes | the self-reference compositional lift: `LiftContext` (`Local`/`InVM`/`InContainer` stack) + `SelfRef` + the pure `foldLift` argv fold + the `liftSubcommand` IO seam (`runSelf`); the subcommand-level superset of `HostTarget` |
| `HostBootstrap.Container` | 13 | yes | the project-container build (build #3): pure `dockerBuildArgs`/`projectImageTag` + `buildProjectContainer` (`docker build` `FROM` the base, tagged `<project>:local`) |
| `HostBootstrap.RoleLifecycle` | 14 | yes | the role-lifecycle skeleton: the `RolePhase` enum + pure `rolePhases` ordering + `RoleSpec`/`runRole` (acquire→serve→drain, drain via `finally`) — the `HostDaemon` substrate L1 builds roles on |
| `HostBootstrap.Incus` | 11 | yes | incus VM lifecycle argv (`launch`/`exec`/`restart`/`delete`, name-guarded) + `classifyDockerReadiness` |
| `HostBootstrap.Ensure.Incus` | 11 | yes | `ensure incus` install-and-verify reconciler (cross-substrate) |

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

## Static-base hostbootstrap.dhall schema

The static-base `hostbootstrap.dhall` is the one config tier the Python bootstrapper reads; it is
identical in shape across projects. It carries only the fields Python needs before any project
binary exists:

| Field | Type | Read by |
|-------|------|---------|
| `project` | `Text` | Python bootstrapper |
| `dockerfile` | `Text` | Python bootstrapper |
| `resources` | `{ cpu : Natural, memory : Text, storage : Text }` | Python bootstrapper, then copied into the host binary context |

The resource budget is consumed at runtime through the **binary context**, and the project binary applies
the cordon from that context (see [development_plan_standards.md § O](development_plan_standards.md) and
§ X). The rich project-level Dhall (runtime roles + cluster-bootstrap instructions) and per-case test
Dhall are **generated by the project binary**, which also emits its own schema; `hostbootstrap-core` owns
the static-base-schema decoder for bootstrap support and the explicit `config show FILE` inspection path
(see [development_plan_standards.md § Q](development_plan_standards.md)). The static-base tier is read
**pre-binary by the Python bootstrapper via the pinned `dhall-to-json`** (`dhall_tool.py`, retained); the
in-process Haskell decoder (`HostBootstrap.Config.Schema`, Phase 4) remains for inspection/bootstrap
support while normal command preconditions use the sibling context. An anti-drift check keeps
`Type.dhall` and the Python-side `package.dhall` the same shape.

## Binary-context config

The runtime context authority is:

| Artifact | Created by | Read by | Purpose |
|----------|------------|---------|---------|
| `./.build/project-binary-context-config.dhall` | Python bootstrapper after the host-native build | host binary | host-orchestrator identity, capabilities, budget envelope, and child-context rules |
| VM-local `project-binary-context-config.dhall` | parent project binary before VM exec/bootstrap | VM binary | fresh-host context and allowed VM-local work |
| `/usr/local/bin/project-binary-context-config.dhall` | project Dockerfile via `--create-container-config` | container binary | container build/test context before `check-code` and lifted test workflows |
| service sibling/mounted context | Kubernetes controller, `StatefulSet` for durable services | service pod binary | service/daemon role context and local cluster capabilities |

The context type is project-extensible, but every normal command must fail fast with exit code 1 when
the sibling context is missing, malformed, for another binary, claims unavailable capabilities, or does not
authorize the requested command.

## Thin Python bootstrapper surface

The Python bootstrapper's surface is only what must run before any project binary exists (see
[development_plan_standards.md § M](development_plan_standards.md)):

| Step | Responsibility |
|------|----------------|
| 1 | assert the fail-fast host minimums |
| 2 | ensure the host toolchain prerequisites needed to **build** the binary (Homebrew → `ghcup` → GHC/Cabal on Apple; `ghcup` → GHC/Cabal on Linux) |
| 3 | build the project binary **host-native** (every substrate) |
| 4 | write `./.build/project-binary-context-config.dhall` from the static bootstrap input |
| 5 | exec the binary |

The bootstrapper does **not** ensure Docker, build the project container, size a VM, or copy a binary
out of a container — those are the project binary's job once it is running (§ M, § N). All other
host-management logic lives in `hostbootstrap-core`; new host logic defaults to the project binary
(Haskell), and a Python addition must be justified by the pre-binary bootstrapping constraint. This
five-step boundary is implemented in `hostbootstrap/bootstrap.py`.

## Host-native binary build

Every project's binary is built **host-native** on every substrate — not built in a container and copied
out (a Linux-container binary cannot exec on a general host such as Apple silicon). The universal
pre-binary dependency is then the **build toolchain**, not Docker (see
[development_plan_standards.md § N](development_plan_standards.md)).

| Substrate | Binary build | Run location | Notes |
|-----------|--------------|--------------|-------|
| `apple-silicon` | host-native (Python ensures Homebrew → `ghcup` → GHC/Cabal) | host | a Linux ELF cannot exec on macOS |
| `linux-cpu`, `linux-gpu` | host-native (Python ensures the host `ghcup` → GHC/Cabal toolchain) | host | no container copy-out |
| Tart (Apple, build-only) | Tart VM (Swift/Metal artifacts → `./.build/`) | host | no built binary runs inside the Tart VM |

A `./.build/<binary>` is always present on the host. The project **container** (the workload image and the
mandatory code-check quality gate) is built by the **project binary** via Docker, once it is running —
not by the Python layer.

## Resource budget and cordoning

The **project binary** verifies the active binary context's resource envelope and applies the cordon: on
Apple by sizing a dedicated per-project Colima/incus VM (via `ensure docker`), on Linux by applying kind
node resource limits (via `cluster up`); the Python bootstrapper does not cordon (it no longer sizes any
VM — Phase 6, Sprint 6.3). The applied cordon is **landed** (Phase 9): `cluster up` runs the
`verifyBudget` spare-capacity preflight and applies the Linux `docker update` kind-node cordon after
`kind create`, before Helm, fail-closed (live `docker`/`incus` execution exercised in real runs). The
cluster lifecycle never deletes host `.data`. The production-vs-test cluster profile distinction selects
fixed names / `.data` paths for production and per-case isolated paths for the test profile. See
`HostBootstrap.Cluster.Cordon` and `HostBootstrap.Cluster.Lifecycle` (Phase 5).

## Base image and warm Cabal store

The base image warms the `hostbootstrap-core` dependencies into the frozen Cabal store. It bakes
**no** `hostbootstrap` binary: a Linux ELF cannot run on Apple silicon, so it could not be copied out
to every host. Every project builds its own binary **host-native**; the project container the binary
later builds (`FROM` the base) is accelerated by the warm store.

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
entrypoint `runHostBootstrapCLI progName projectCommands testSuite` (`HostBootstrap.CLI`, Phase 1;
command tree in `HostBootstrap.Command`, Phase 4; test suite hook from Phase 10). A project binary
extends the core tree with its own subcommands and supplies its test suite rather than re-implementing
core verbs. The bare `hostbootstrap` binary (`hostbootstrap-core`'s own executable) is the core tree with
no project commands and `emptySuite`, built like any project binary rather than baked into the base image.
See
[development_plan_standards.md § P](development_plan_standards.md).

| Core verb group | Phase | Source |
|-----------------|-------|--------|
| `ensure <tool>` (incl. `incus`) | 3, 11 | the `ensure` reconcilers |
| `context create vm\|container\|service` / `--create-container-config` | 15.3, 15.4 | `HostBootstrap.Context` |
| `config show` (static-base inspection) | 4 | `HostBootstrap.Config.Schema` |
| `config schema` / `config render` | 8 | `HostBootstrap.Dhall.Gen` + the `ConfigArtifact` registry |
| `cluster up/down/delete/status` | 5 | `HostBootstrap.Cluster.Lifecycle` |
| `test <case\|all>` | 10 | `HostBootstrap.Harness` (`runSuiteSelection` / `runMatrix`) |
| `check-code` | 10 | project-defined body, the image-build gate |

## hostbootstrap-demo (worked consumer)

`hostbootstrap-demo` (Phase 13) is the self-contained worked consumer under `demo/` (own static-base
`hostbootstrap.dhall`, Haskell source `demo/app/Main.hs` + `demo/src/HostBootstrapDemo/Commands.hs`, build
path `demo/.build`). It extends `hostbootstrap-core` directly (L0-direct) via `runHostBootstrapCLI` and
demonstrates the four-stream extension — the CLI append (`incus`/`vm`/`harbor`/`web` noun verbs alongside
the inherited core verbs), the schema-gen concat (`demo web schema` → `coreArtifacts ++ demoArtifacts`),
and the harness (`demo test all` → `runMatrix` over the demo's case matrix, bound to the inherited `test`
verb). The demo's four runtime contexts are explicit: host, VM, container on the VM, and
cluster-service pod. Its verbs drive the live surface — `ensure incus`, the host-provider axis, the
applied budget cordons, an idiomatic in-Dockerfile `check-code` gate (`demo/docker/Dockerfile`), a
`purescript-bridge`/`spago` webservice and SPA, and Playwright e2e — centered on a from-zero
pristine-host bootstrap inside an incus VM. It supersedes the retired
`core/hostbootstrap-core/example/Main.hs`.

## Update rule

When the host-management architecture changes (a new `HostBootstrap.*` module, a new `ensure`
reconciler — including a host-provider like `incus`, a static-base-schema field, a binary-context field
or command-gating rule, a base-image or warm-store change — including a freeze-fragment split, a new core
command-tree verb, a new run-model, or the worked-consumer demo), update this inventory in the same
change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single source of
truth for the host-management component set.
