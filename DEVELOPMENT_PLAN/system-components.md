# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative inventory of every component the host-management layer produces or
> consumes — `hostbootstrap-core` module surfaces, the `ensure` reconcilers and their host
> applicability, the project-local `<project>.dhall` schema, the runtime context fields inside that
> config, the thin Python bootstrapper surface, the base image and warm Cabal store, and the optparse
> command tree projects extend.

> Note: the inversion buildout (Phases 1–7) is implemented — the `HostBootstrap.*` modules below exist,
> the Python CLI is the thin `doctor` / `build` / `run` / `base` pre-binary bootstrapper (converged on the
> §M/§N boundary), and `hostbootstrap-core` is consumable via `runHostBootstrapCLI`. The
> **global-architecture deltas** are implemented and unit-tested — Dhall generation (Phase 8),
> the applied cordon (Phase 9), the standardized harness (Phase 10), and the incus host-provider
> (Phase 11) are all landed; the layered warm store (Phase 12) and the worked demo (Phase 13) are
> implemented and **exercised in real runs** (incus VMs, the pristine 3-build bootstrap, the harness
> cluster lifecycle, the web/Playwright stack). Phase 4's project-local schema work, Phase 6's Python
> Dhall removal, Phase 8's config generation, Phase 13's demo migration, and Phase 15's command-gate
> migration are closed. The **single-representation
> doctrine** ([development_plan_standards.md § W](development_plan_standards.md) — one operation, one
> representation; the standardized test harness is the one representation, **lifted** into the project
> container in the VM via `incus exec <vm> -- docker run --rm <image> test all`, with no parallel deploy
> chain alongside it) is **implemented and live-validated**: Phase-13 Sprint 13.12 collapsed the demo deploy
> to the single lift sequence, and the literal `demo deploy` apply runs `3/3` with the kind cluster on the
> **VM's** Docker (poller-confirmed in the VM, none on metal), guarded teardown, no leftovers. The earlier
> metal-host in-container runs were a dev shortcut, superseded by the in-VM lift. The operator-scale
> real runs (multi-arch published base tags, the full Harbor deployment, the multi-GB image push) follow
> the § Validation Policy standard. The rows below carry their owning phase and an
> Implemented column. The target runtime authority is a sibling `<project>.dhall` for host, VM,
> ad-hoc-container, and service/daemon copies of a binary, with the role and command permissions inside
> the file content. The
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
| `HostBootstrap.Config.Schema` | 4, 8, 15 | yes | project-local `<project>.dhall` schema/default/projection substrate; sibling project-config discovery and command-gate loading |
| `HostBootstrap.Context` | 15.1, 15.3, 15.4, 15.5 | yes | runtime context type embedded inside `<project>.dhall`: host/VM/container/service constructors, validation, exit-code-1 failure helpers, and role/capability/command authority |
| `HostBootstrap.Command` | 4, 15.4 | yes | the core command tree projects extend; normal core commands gate through the sibling binary context |
| `HostBootstrap.Cluster.Lifecycle` | 5 | yes | kind/Helm cluster up/down/delete semantics |
| `HostBootstrap.Cluster.Cordon` | 5, 9 | yes | the one canonical `parseQuantity`, budget verification, the full `colima`/kind-node argv builders, `verifyBudget`/`fitsBudget`, and the applied `docker update` kind-node cordon |
| `HostBootstrap.DocValidator` | 0 | yes | mechanical documentation validator run through the code-check |
| `HostBootstrap.Config.Vocab` | 8 | yes | Haskell mirrors of the `Core.dhall` vocabulary record types (reflected for schema-gen) |
| `HostBootstrap.Dhall.Gen` | 8 | yes | the Dhall-generation substrate + the `ConfigArtifact` registry (reflected schema + render); `config schema` also includes the reflected project-local config schema |
| `HostBootstrap.Dhall.Hoist` | 8, 15 | yes | post-pass that hoists the repeated vocabulary unions (`ContextKind`/`Capability`/`CommandClass`) into top-level `let` bindings before pretty-printing, so generated `<project>.dhall`/context files stay compact and standalone; shared by `renderProjectConfig` and `renderContext` |
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

## Project-local `<project>.dhall` schema

The target user-editable runtime config is a sibling `<project>.dhall`, where `<project>` is derived from
the Cabal file name (`hostbootstrap-demo.cabal` -> `hostbootstrap-demo`). Python does not read this file;
it only triggers the binary's idempotent `config init --if-missing` after the build so a default always
exists. The built project binary creates the file through `<project> config init`, prints its schema/help,
and reads it before normal command dispatch.

| Field family | Read by | Purpose |
|--------------|---------|---------|
| Project identity | project binary | derived project name, source root, binary name, and config version |
| Build inputs | project binary | Dockerfile path, container resources, image/tag defaults, build roots |
| Runtime context | project binary | context kind, role name, allowed command classes, local capabilities, parent chain |
| Resource envelope | project binary | host/VM/container/service budget limits and child projection defaults |
| Deploy knobs | project binary | HA replicas, service sizing, generated child-config inputs |

The old demo static-base file, Haskell `StaticBase` compatibility API, separate standalone context filename,
and Dockerfile shortcut are removed. Those deletions are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Runtime context inside local config

The runtime authority is:

| Artifact | Created by | Read by | Purpose |
|----------|------------|---------|---------|
| `./.build/<project>.dhall` | `<project> config init` or user-supplied config | host binary | host-orchestrator identity, capabilities, budget envelope, Dockerfile/build inputs, and child-config rules |
| VM-local `<project>.dhall` | parent project binary before VM exec/bootstrap | VM binary | fresh-host context and allowed VM-local work |
| `/usr/local/bin/<project>.dhall` | project Dockerfile via `<project> config init --role vm-project-container --output /usr/local/bin/<project>.dhall` | ad-hoc container binary | container build/test context before `check-code` and lifted test workflows |
| service sibling/mounted `<project>.dhall` | project binary/controller during cluster bring-up | service pod binary | service/daemon role context, local cluster capabilities, replica/resource knobs |

Every normal command must fail fast with exit code 1 when the sibling config is missing, malformed, for
another project, claims unavailable capabilities, or does not authorize the requested command. Help,
version, `config init`, `config schema`, `config show`, `config path`, and static `config render` are the
bootstrap/inspection exceptions. Daemons read one immutable config snapshot at startup, log the config
path and hash, and do not live-reload by default.

## Thin Python bootstrapper surface

The Python bootstrapper's surface is only what must run before any project binary exists (see
[development_plan_standards.md § M](development_plan_standards.md)):

| Step | Responsibility |
|------|----------------|
| 1 | assert the fail-fast host minimums |
| 2 | ensure the host toolchain prerequisites needed to **build** the binary (Homebrew → `ghcup` → GHC/Cabal on Apple; `ghcup` → GHC/Cabal on Linux) |
| 3 | derive the project name from the Cabal file and build the project binary **host-native** (every substrate) |
| 4 | trigger the binary's idempotent `config init --if-missing` so a default `./.build/<project>.dhall` always exists (the binary writes the Dhall) |
| 5 | exec the binary |

The bootstrapper does **not** read or write Dhall itself (step 4 only *triggers* the binary's own config
surface), ensure Docker, build the project container, size a VM,
or copy a binary out of a container — those are the project binary's job once it is running (§ M, § N).
All other host-management logic lives in `hostbootstrap-core`; new host logic defaults to the project
binary (Haskell), and a Python addition must be justified by the pre-binary bootstrapping constraint. The
current `hostbootstrap/bootstrap.py` derives the project name from the Cabal file, triggers the binary's
`config init --if-missing`, and writes no Dhall itself.

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

The **project binary** verifies the active `<project>.dhall` resource envelope and applies the cordon: on
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
| `config init` (incl. idempotent `--if-missing`) / `config path` | 8, 15 | `HostBootstrap.Config.Schema` + `HostBootstrap.Context` |
| `context create vm\|container\|service` | 15.3, 15.4 | target child `<project>.dhall` projections |
| `config show` | 4, 15 | explicit inspection of a local config file |
| `config schema` / `config render` | 8 | `HostBootstrap.Dhall.Gen` + the `ConfigArtifact` registry |
| `cluster up/down/delete/status` | 5 | `HostBootstrap.Cluster.Lifecycle` |
| `test <case\|all>` | 10 | `HostBootstrap.Harness` (`runSuiteSelection` / `runMatrix`) |
| `check-code` | 10 | project-defined body, the image-build gate |

## hostbootstrap-demo (worked consumer)

`hostbootstrap-demo` (Phase 13) is the self-contained worked consumer under `demo/` (target
`hostbootstrap-demo.dhall`, Haskell source `demo/app/Main.hs` + `demo/src/HostBootstrapDemo/Commands.hs`,
build path `demo/.build`). It extends `hostbootstrap-core` directly (L0-direct) via `runHostBootstrapCLI` and
demonstrates the four-stream extension — the CLI append (`incus`/`vm`/`harbor`/`web` noun verbs alongside
the inherited core verbs), the schema-gen concat (`demo web schema` → `coreArtifacts ++ demoArtifacts`),
and the harness (`demo test all` → `runMatrix` over the demo's case matrix, bound to the inherited `test`
verb). The demo's four runtime contexts are explicit sibling `hostbootstrap-demo.dhall` files: host, VM,
container on the VM, and cluster-service/daemon pod. Its verbs drive the live surface — `ensure incus`,
the host-provider axis, the
applied budget cordons, an idiomatic in-Dockerfile `check-code` gate (`demo/docker/Dockerfile`), a
`purescript-bridge`/`spago` webservice and SPA, and Playwright e2e — centered on a from-zero
pristine-host bootstrap inside an incus VM. It supersedes the retired
`core/hostbootstrap-core/example/Main.hs`.

## Update rule

When the host-management architecture changes (a new `HostBootstrap.*` module, a new `ensure`
reconciler — including a host-provider like `incus`, a project-local-config field, a runtime-context
field or command-gating rule, a base-image or warm-store change — including a freeze-fragment split, a
new core command-tree verb, a new run-model, or the worked-consumer demo), update this inventory in the
same change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single source of
truth for the host-management component set.
