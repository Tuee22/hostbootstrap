# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative inventory of every component the host-management layer produces or
> consumes — `hostbootstrap-core` module surfaces, the `ensure` reconcilers and their host
> applicability, the project-local `<project>.dhall` schema, the runtime context fields inside that
> config, the thin Python bootstrapper surface, the base image and warm Cabal store, and the optparse
> command tree projects extend.

> Note: Phases 0-20 landed `Done`, and the Windows third-substrate reopening is now closed for phases 2,
> 3, and 9. Windows joins as the third metal substrate (`windows-cpu`/`windows-gpu`), Tart retires from
> the prose, and composition pattern #7 re-anchors to a headless host build (`ensure cudawin` first).
> Phase 11 remains `Active`: the WSL2 provider is implemented and unit-validated, and `ensure wsl2` has
> reconciled WSL2 platform readiness on the post-reboot host (`HyperVisorPresent = True`, default WSL
> version 2). The live Windows chain reaches the managed Ubuntu-24.04 distro and in-distro Docker image
> build, but repeated WSL/Docker sessions exit non-zero before `test run all` and `project destroy` close
> the lifecycle; that real-run provider validation remains open.
> The **generic-project-model** work (phase 19, § BB) is `Done` —
> phase-close code-check-validated (core 237 + demo 13) and real-run-validated 2026-06-23 (test run all 3/3 from a
> harness-generated config) — and builds **forward**: it reopened, undid, or reversed no earlier phase.
> Phases 4, 8, 10, 15, and 17 stay `Done` with forward-pointers. `hostbootstrap-core` owns **no hardcoded
> defaults** and is parameterized over a project's own config type (`ProjectSpec cfg tcfg`), with `project
> init` and the harness sharing one project-owned `psInit`, the harness **generating** the run's
> `<project>.dhall` from a thin `test.dhall` override, a pure `SecretRef` vocabulary for secrets-strict
> consumers, and the Python bootstrapper no longer initializing config (Python builds the host-native binary
> and execs it; the binary owns config init and fails fast when the sibling config is absent — Sprint 19.5).
> Phase 20 (`Done`) is the
> config-driven demo worked example: it adds a project-owned `message` field to the demo (config→web→SPA),
> a two-variant run, and a polymorphic Playwright assertion, with **no core change** — real-run-validated
> 2026-06-23 (`test run all` `6/6` across two message variants with full teardown between) (see
> [phase-19-generic-project-model.md](phase-19-generic-project-model.md),
> [phase-20-config-driven-demo-worked-example.md](phase-20-config-driven-demo-worked-example.md)). The
> module rows below describe the **current concrete** surface (the demo's `ProjectConfig`); phase 19 makes
> the **types** generic without changing the fixed command tree. [Phase 21](phase-21-documentation-code-consistency-reconciliation.md) (`Done`) reconciles the docs and
> small code surfaces to that current state: no standalone `ensure` command, generic `chain :: cfg ->
> [Step]`, deleted `Type.dhall`, retained `example.dhall`, and kind delete-on-down with durable-state
> preservation. The **unified-harness / fixed-surface /
> resource-SSoT** correction (phases 10/13/14/15/16/17/18) is complete — code-check-validated and
> real-run-validated end-to-end (the
> full `project up` lifecycle + `test run all` `3/3 passed` on both Incus/Linux and a 16 GiB Apple-Silicon
> host, 2026-06-20). The
> command surface is **fixed** to `project` / `test` / `service` / `context` / `check-code` — no per-project
> verbs; `hostbootstrap-core` is a **library of composable tools**, not a CLI topology (§ P). The test
> harness **drives the real `project up`** under a test config rather than re-expressing bring-up (§ W); the
> declared budget is the **one ceiling = the VM wall** with the cluster a **slice within it** (§ O); each
> `<project>.dhall` carries an explicit, possibly multi-role context generated from forwarded parameters
> (§ X); long-running roles run through the new `service` command (§ AA). The rows below name the supported
> component surfaces, their owning phases, and whether the repository implements them. Runtime authority is
> a sibling `<project>.dhall` for each host, VM, container, and service/daemon copy of a binary, with role
> and command permissions inside the file content, including provider-backed topology frames, a current
> frame, and runtime witnesses. The Python CLI is the thin `doctor` / `build` / `run` / `base` surface
> consuming Phase 2's pre-binary bootstrap plus the explicit `update` pipx self-update surface, and `hostbootstrap-core` is the reusable
> library consumed through `runHostBootstrapCLI progName projectSpec`. The single-representation rule is part
> of the supported architecture: a project's deploy is its one pure `chain :: cfg -> [Step]` value
> interpreted recursively by `project up`, and the standardized test harness drives that same chain.
>
> **Current suite SSoT:** `core 239 + demo 14` static Haskell `testCase` definitions; run the core suite
> with `cabal test` from `core/` and the demo suite with `cabal test` from `demo/`.

## hostbootstrap-core Haskell module surface

The library lives under the `HostBootstrap.*` namespace. The module names below are the supported
surface; the column records whether the module exists in this repository.

| Module | Phase | Implemented | Purpose |
|--------|-------|-------------|---------|
| `HostBootstrap.CLI` | 1, 16 | yes | `ProjectSpec`, `runHostBootstrapCLI progName projectSpec`, and `runBareHostBootstrapCLI`; validated optparse entrypoints. The surface is **fixed** (`project` / `test` / `service` / `context` / `check-code`); `ProjectSpec` carries no `ProjectCommand` deltas — a project extends core via the chain, Dhall vocabulary, schema-gen, test seams, and service handlers (§ P) |
| `HostBootstrap.HostTool` | 2 | yes | closed `HostTool` enumeration; absolute-path resolution |
| `HostBootstrap.HostConfig` | 2 | yes | typed host configuration (lifted from infernix) |
| `HostBootstrap.HostPrereqs` | 2 | yes | fail-fast host minimum checks |
| `HostBootstrap.Substrate` | 2 | yes | substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) |
| `HostBootstrap.Ensure` | 3 | yes | the `Reconciler` value type and library runner used by `ensure-*` chain steps |
| `HostBootstrap.Ensure.Docker` | 3 | yes | `ensure docker` reconciler |
| `HostBootstrap.Ensure.Colima` | 3 | yes | `ensure colima` reconciler |
| `HostBootstrap.Ensure.Cuda` | 3 | yes | `ensure cuda` reconciler |
| `HostBootstrap.Ensure.CudaWin` | 3 | yes | `ensure cudawin` reconciler (CUDA-on-Windows headless host build; first instance of composition pattern #7) |
| `HostBootstrap.Ensure.Homebrew` | 3 | yes | `ensure homebrew` reconciler |
| `HostBootstrap.Ensure.Ghc` | 3 | yes | `ensure ghc` reconciler |
| `HostBootstrap.Ensure.Lima` | 11.6 | yes | `ensure lima` reconciler for the Apple Silicon Lima VM provider |
| `HostBootstrap.Config.Schema` | 4, 8, 15 | yes | project-local `<project>.dhall` schema/default/projection substrate; sibling project-config discovery and command-gate loading |
| `HostBootstrap.Context` | 15.1, 15.3, 15.4, 15.5, 15.6 | yes | runtime context type embedded inside `<project>.dhall`: host/VM/container/image-build/service constructors, topology frames, current-frame identity, runtime witnesses, validation, exit-code-1 failure helpers, and role/capability/command authority |
| `HostBootstrap.Command` | 4, 15.4 | yes | the core command tree projects extend; normal core commands gate through the sibling binary context |
| `HostBootstrap.Cluster.Lifecycle` | 5 | yes | kind/Helm cluster up/down/delete semantics |
| `HostBootstrap.Cluster.Cordon` | 5, 9 | yes | the one canonical `parseQuantity`, budget verification, the full `colima`/kind-node argv builders, `verifyBudget`/`fitsBudget`, `resolveHostCapacity` (substrate-aware spare-capacity resolution — resolved `sysctl` `hw.ncpu`/`hw.memsize` on Apple, `/proc` on Linux), and the applied `docker update` kind-node cordon |
| `HostBootstrap.DocValidator` | 0 | yes | mechanical documentation validator run through the code-check |
| `HostBootstrap.Config.Vocab` | 8 | yes | Haskell mirrors of the `Core.dhall` vocabulary record types (reflected for schema-gen) |
| `HostBootstrap.Dhall.Gen` | 8 | yes | the Dhall-generation substrate + the `ConfigArtifact` registry (reflected schema + render); `config schema` also includes the reflected project-local config schema |
| `HostBootstrap.Dhall.Hoist` | 8, 15 | yes | post-pass that hoists the repeated vocabulary unions (`ContextKind`/`ProviderKind`/`WitnessKind`/`Capability`/`CommandClass`) into top-level `let` bindings before pretty-printing, so generated `<project>.dhall`/context files stay compact and standalone; shared by `renderProjectConfig` and `renderContext` |
| `HostBootstrap.Harness` | 10 | yes | the kept pure cores — `runMatrix` + `Seams` + `sliceBudget` + `selectRunModel` + `guardTestDelete` + the L0 OneShot seam — plus the **recast stack-driven `TestSuite`** `(safety, bring-up, cases, assertion, tear-down)` and `runSuiteSelection`/`testSafetyPreconditions`/`emptySuite`. The engine drives the real `project up` (bring-up) / `project destroy` (tear-down) per test config, enforces the two fail-fast preconditions, owns the run's `.test_data` lifecycle under the self-created-only delete-guard (`testDataRoot` / `selfCreatedTestDataRemoval` / `withSelfCreatedTestData`), and reuses `runMatrix` for the per-case assertions — no second bring-up path (§ W). Built + unit-tested; real-run-validated by `test run all` (`3/3 passed`, 2026-06-20) |
| `HostBootstrap.Service` | 18 | yes | `ServiceHandler` / `ServiceRegistry` (variant name + role action), `lookupServiceHandler` / `serviceVariantNames` / `duplicateServiceVariants`; threaded through `ProjectSpec` (`withServices`). Drives `HostBootstrap.Command.serviceCommandGroup` (`service init\|schema\|run`, no `service down`); `service run` gates as `Context.ServiceCommand` (leaf-frame) then dispatches on the variant (§ AA). Built + unit-tested; real-run-validated — the live web pod runs `service run web` and serves HTTP 200 (2026-06-20) |
| `HostBootstrap.HostTarget` | 11 | yes | `Local \| InVM` target dispatch (`runInTarget`) + the reboot-to-ready loop (the tool-level lift) |
| `HostBootstrap.Lift` | 11, 14, 17 | yes | the self-reference compositional lift: `LiftContext` (`Local`/provider VM/`InContainer` stack) + `SelfRef` + the pure leaf fold `foldLeaf` over `LiftLeaf = SelfSub \| RawCmd` (place /any/ command in a frame — a self-subcommand handoff or a `RawCmd` such as a `reachLeaf` probe / `bash -lc`), with `foldLift` the `SelfSub` special case; the IO seams `liftLeaf` / `liftSubcommand` (`runSelf`) + `liftSubcommandWithAuth` (forwards a Docker Hub credential into a container-through-a-VM frame over stdin, never argv); the subcommand-level superset of `HostTarget`. Frame-placed `RawCmd` probes give provider-agnostic reachability assertions (`incus exec`/`limactl shell -- curl …`) — § 17 native-Linux test parity |
| `HostBootstrap.Registry` | 14 | yes | the effect-only Docker Hub credential capability: opaque `RegistryAuth` (no Dhall codec, redacted `Show`), host-only discovery (`discoverHostRegistryAuth`, Docker-Hub-only projection), and the ephemeral forwarding seams (`dockerAuthStdinWrapper`, `withForwardedRegistryAuth`) that authenticate nested pulls without persisting, leaking, or representing the secret in Dhall |
| `HostBootstrap.Container` | 13 | yes | the project-container build (build #3): pure `dockerBuildArgs`/`projectImageTag` + `buildProjectContainer` (`docker build` `FROM` the base, tagged `<project>:local`) |
| `HostBootstrap.RoleLifecycle` | 14 | yes | the role-lifecycle skeleton: the `RolePhase` enum + pure `rolePhases` ordering + `RoleSpec`/`runRole` (acquire→serve→drain, drain via `finally`) — the `HostDaemon` substrate L1 builds roles on |
| `HostBootstrap.Incus` | 11 | yes | incus VM lifecycle argv (`launch`/`exec`/`restart`/`delete`, name-guarded) + `classifyDockerReadiness` |
| `HostBootstrap.Lima` | 11.6 | yes | Lima VM lifecycle argv for Apple Silicon demo execution (`start`, `shell`, `copy`, `list`, name-guarded `delete`) |
| `HostBootstrap.Wsl2` | 11 | yes | WSL2 (Ubuntu-24.04) VM lifecycle argv on Windows — the incus/lima host-provider VM peer (`install`/`import`/`exec`/`terminate`, distro-guarded) |
| `HostBootstrap.Ensure.Incus` | 11 | yes | `ensure incus` install-and-verify reconciler (Colima-backed provider on Apple, native daemon on Linux) |
| `HostBootstrap.Ensure.Wsl2` | 11 | yes | `ensure wsl2` install-and-verify reconciler for the Windows WSL2 host-provider (the incus/lima peer) |
| `HostBootstrap.Command` (project group) | 16 | yes | the `project init\|up\|down\|destroy` lifecycle command (§ Y): `project up --dry-run` renders the chain through the context gate; the chain is threaded through `ProjectSpec` (`psChain`/`psFrameContext`); the effectful apply (recursive provisioning) and VM stop-without-delete are real-run-validated end-to-end on Incus/Linux and Apple Silicon |
| `HostBootstrap.Step` | 16 | yes | the `Step` algebra (§ Y): the closed core host-management `StepKind` set plus the open `ProjectStep` seam interleaved in one `[Step]`, with the pure `renderChainPlan` dry-run render and `stepsForFrame`/`chainFrames` segmentation |
| `HostBootstrap.Chain` | 16 | yes | the recursive chain interpreter (§ Y): pure `renderChain` (`--dry-run`), `nextFrameAfter` (descent order), `handoffDispatch` (the `project up` argv fold), and the `runChainFromFrame` effectful seam; end-to-end provisioning is real-run-validated |

`HostBootstrap.HostTool`, `HostBootstrap.HostConfig`, and `HostBootstrap.HostPrereqs` are lifted from
[`infernix`](https://github.com/Tuee22/infernix), which is the source of the host trio.

## Host-tool resolution

External tools resolve through a closed `HostTool` enumeration to absolute paths
(`HostBootstrap.HostTool`, Phase 2). No library or project code calls `proc "<bare-command-name>"`
that resolves through `$PATH`; every invocation reads an absolute path from typed host configuration.
`Sysctl` is part of this closed enum for Apple-silicon host-capacity reads; it is a host tool, not an
`ensure` reconciler. On Windows the closed enum adds `Winget` (the Homebrew-analog pre-binary package
manager), `Nvcc` (CUDA-on-Windows toolchain verification for `ensure cudawin`), `Wsl` (WSL2
host-provider control), and `Bcdedit` (Windows hypervisor launch reconciliation for `ensure wsl2`);
`Tart` is no longer a member of the enum.
See [development_plan_standards.md § K](development_plan_standards.md).

## Ensure reconcilers and host applicability

Each host dependency is an idempotent `ensure` reconciler: a host-applicability predicate plus a
reconcile action, exposed to projects as a library primitive and composed into `ensure-*` chain steps.
There is no top-level `ensure` command and no hidden command surface. A reconciler run on the wrong host fails fast
with a one-line diagnostic and a non-zero exit. See
[development_plan_standards.md § L](development_plan_standards.md).

| Subcommand | Module | Phase | Applicable hosts | On wrong host |
|------------|--------|-------|------------------|---------------|
| `ensure docker` | `HostBootstrap.Ensure.Docker` | 3 | all substrates | n/a (universal) |
| `ensure colima` | `HostBootstrap.Ensure.Colima` | 3 | `apple-silicon` | fail fast, non-zero |
| `ensure cuda` | `HostBootstrap.Ensure.Cuda` | 3 | `linux-gpu` | fail fast, non-zero |
| `ensure cudawin` | `HostBootstrap.Ensure.CudaWin` | 3 | `windows-gpu` (CUDA-on-Windows headless host build) | fail fast, non-zero |
| `ensure homebrew` | `HostBootstrap.Ensure.Homebrew` | 3 | `apple-silicon` | fail fast, non-zero |
| `ensure ghc` | `HostBootstrap.Ensure.Ghc` | 3 | `apple-silicon` (host-native build path) | fail fast, non-zero |
| `ensure lima` | `HostBootstrap.Ensure.Lima` | 11.6 | `apple-silicon` (pristine demo VM provider) | fail fast, non-zero |
| `ensure incus` | `HostBootstrap.Ensure.Incus` | 11 | `apple-silicon` **and** `linux-cpu`/`linux-gpu` (install-and-verify; Colima-backed on Apple, native daemon on Linux) | fail fast, non-zero |
| `ensure wsl2` | `HostBootstrap.Ensure.Wsl2` | 11 | `windows-cpu`/`windows-gpu` (install-and-verify; WSL2 platform readiness for the incus/lima peer; project VM steps register the project-named Ubuntu-24.04 distro) | fail fast, non-zero |

## Project-local `<project>.dhall` schema

The user-editable runtime config is a sibling `<project>.dhall`, where `<project>` is derived from
the Cabal file name (`hostbootstrap-demo.cabal` -> `hostbootstrap-demo`). Python does not read, write, OR
initialize this file: it builds the host-native binary and execs it; the binary owns config init and fails
fast (exit 1) when the sibling config is absent. The config is created by an explicit `<project> project
init` or generated by the test harness (`psTestConfig`). The built project binary creates the file through
`<project> project init`, prints its schema/help, and reads it before normal command dispatch.

> Under § BB (phase 19, `Done`), the config **type** is **project-defined** (`ProjectSpec cfg tcfg`), not
> the fixed `ProjectConfig` below: `hostbootstrap-core` owns **no default config values**, every field is
> mandatory and fails the strict decode if omitted, defaults live only in a project-owned `psInit` (and
> `project init` layers optional flag overrides over the project's `psInit` defaults), and secret fields use
> the pure `SecretRef` vocabulary so a production config is plaintext-free
> ([secrets.md](../documents/engineering/secrets.md)). Phase 20 adds the demo's own `message : Text` field
> on top of this (a field on the demo's `cfg`, not a core field and not a generic extra slot — see the
> `message` row below). The field families below are the **demo's** concrete `ProjectConfig`; the resource
> envelope in particular is a provider concern carried by a project's `cfg`, not a universal field
> (§ BB refines § O).

| Field family | Read by | Purpose |
|--------------|---------|---------|
| Project identity | project binary | derived project name, source root, binary name, and config version |
| Build inputs | project binary | Dockerfile path, container resources, image/tag defaults, build roots |
| Runtime context | project binary | parent chain, topology frames, current frame, runtime witnesses, context kind, role name, allowed command classes, local capabilities |
| Resource envelope | project binary | host/VM/container/service budget limits and child projection defaults |
| Deploy knobs | project binary | HA replicas, service sizing, generated child-config inputs |
| `message` (demo's own field, phase 20) | project binary / service pod | user-visible SPA message; flows `<project>.dhall` -> the chart ConfigMap -> the `Web` service (`serveWeb`) -> `BudgetView.message` -> the SPA `#message` (config→web→SPA). A field on the demo's **own** `cfg`, not a core field and not a generic extra slot |

## Runtime context inside local config

The runtime authority is:

| Artifact | Created by | Read by | Purpose |
|----------|------------|---------|---------|
| `./.build/<project>.dhall` | `<project> project init` or user-supplied config | host binary | host-orchestrator identity, capabilities, budget envelope, Dockerfile/build inputs, and child-config rules |
| VM-local `<project>.dhall` | parent project binary before VM exec/bootstrap | VM binary | fresh-host context and allowed VM-local work |
| `/usr/local/bin/<project>.dhall` baked in image | project Dockerfiles via `<project> project init --role image-build-container --output /usr/local/bin/<project>.dhall` | project container binary during image build | build/code-quality and config-generation authority only |
| `/usr/local/bin/<project>.dhall` mounted at runtime | parent project binary before `docker run` | project container binary at runtime | frame-specific runtime authority, such as VM-project-container `test all`, with topology witnesses |
| service sibling/mounted `<project>.dhall` | project binary/controller during cluster bring-up | service pod binary | service/daemon role context, local cluster capabilities, replica/resource knobs |

Every normal command must fail fast with exit code 1 when the sibling config is missing, malformed, for
another project, claims unavailable capabilities, or does not authorize the requested command. Help,
version, `project init`, and the read-only `context` introspection command (which absorbs
`config show` / `config schema` / `config path` / static `config render`) are the bootstrap/inspection
exceptions (§ Z); the flat `config` and `context create` verbs are removed. Daemons read one immutable config snapshot at startup, log the config
path and hash, and do not live-reload by default.

## Thin Python bootstrapper surface

The Python bootstrapper's surface is only what must run before any project binary exists (see
[development_plan_standards.md § M](development_plan_standards.md)):

| Step | Responsibility |
|------|----------------|
| 1 | assert the fail-fast host minimums |
| 2 | ensure the host Haskell toolchain prerequisites and Cabal package index needed to **build** the binary (Homebrew → `ghcup` → GHC/Cabal on Apple; `ghcup` → GHC/Cabal on Linux; winget-rooted GHCup → GHC/Cabal on Windows; then `cabal update`) |
| 3 | derive the project name from the Cabal file and build the project binary **host-native** (every substrate) |
| 4 | exec the binary |

Python builds the host-native binary and execs it; it does **not** read, write, OR initialize Dhall. The
binary owns config init and fails fast (exit 1) when the sibling config is absent — the config is created by
an explicit `project init` or generated by the test harness (`psTestConfig`). The bootstrapper also does not
ensure Docker, build the project container, size a VM,
or copy a binary out of a container — those are the project binary's job once it is running (§ M, § N).
All other host-management logic lives in `hostbootstrap-core`; new host logic defaults to the project
binary (Haskell), and a Python addition must be justified by the pre-binary bootstrapping constraint. The
current `hostbootstrap/bootstrap.py` derives the project name from the Cabal file, builds the host-native
binary and execs it; it does not initialize or trigger config creation and writes no Dhall itself
(phase 19 Sprint 19.5).

The pre-binary floor/toolchain bootstrap is owned by Phase 2 so it can make `cabal` available before any
Haskell phase validation gate runs. Firmware virtualization is a host-floor fact. WSL2 feature activation,
Windows hypervisor launch readiness, distro registration, and provider usability are not Python
pre-binary gates; they are reconciled by the built binary through Phase 11.

The Python CLI command surface is:

| Command | Phase | Implemented | Purpose |
|---------|-------|-------------|---------|
| `hostbootstrap doctor` | 2, 6 | yes | detect the host and assert the Phase-2 fail-fast host minimums |
| `hostbootstrap build` | 2, 6 | yes | consume the Phase-2 toolchain bootstrap and build the project binary host-native into `./.build/` without execing it |
| `hostbootstrap run` | 2, 6 | yes | consume the Phase-2 toolchain bootstrap, build idempotently, then exec the project binary |
| `hostbootstrap base build` | 6 | yes | cold-rebuild base image tags locally |
| `hostbootstrap base build-and-push` | 6 | yes | cold-rebuild and publish base image tags when the operator explicitly requests it |
| `hostbootstrap update` | 6.5 | yes | explicit pipx self-update of the Python bootstrapper; no automatic latest-version gate |

## Host-native binary build

Every project's binary is built **host-native** on every substrate — not built in a container and copied
out (a Linux-container binary cannot exec on a general host such as Apple silicon). The universal
pre-binary dependency is then the **build toolchain**, not Docker (see
[development_plan_standards.md § N](development_plan_standards.md)).

| Substrate | Binary build | Run location | Notes |
|-----------|--------------|--------------|-------|
| `apple-silicon` | host-native (Python ensures Homebrew → `ghcup` → GHC/Cabal) | host | a Linux ELF cannot exec on macOS |
| `linux-cpu`, `linux-gpu` | host-native (Python ensures the host `ghcup` → GHC/Cabal toolchain) | host | no container copy-out |
| `windows-cpu`, `windows-gpu` | host-native (Python ensures winget → `ghcup` → GHC/Cabal mingw32 toolchain, building the native `hostbootstrap.exe`) | host | peer of the Apple-silicon path; a Linux ELF cannot exec on Windows |

A `./.build/<binary>` is always present on the host. The project **container** (the workload image and the
mandatory code-check quality gate) is built by the **project binary** via Docker, once it is running —
not by the Python layer.

## Resource budget and cordoning

The **project binary** verifies the active `<project>.dhall` resource envelope and applies the cordon: on
Apple demo VM workloads run behind a Lima VM; Incus host-provider workflows use `incusSizingArgs`
at the VM wall on native Linux; `cluster up` applies kind
node resource limits. The Python bootstrapper does not cordon a project's VM or cluster. The one exception
is the maintainer base-image build: `hostbootstrap base build` measures host CPU/RAM
(`hostbootstrap/resources.py`) and applies docker `--memory`/`--cpus` caps plus a host-sized `cabal -j` to
the base-image **build container** — a build-phase limit on the warm-store compile, not a project runtime
cordon (see `documents/engineering/base_image.md`). `cluster up` runs the `verifyBudget`
spare-capacity preflight and applies the Linux `docker update` kind-node cordon after `kind create`,
before Helm, fail-closed (live `docker`/`incus` execution exercised in real runs). The preflight resolves
spare host capacity per substrate (resolved `sysctl` `hw.ncpu`/`hw.memsize` on Apple silicon, `/proc` on
Linux). The cluster lifecycle
never deletes host `.data`. The production-vs-test cluster profile distinction selects fixed names /
`.data` paths for production and per-case isolated paths for the test profile. See
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
| Node web tooling + Playwright | `spago`, `esbuild`, and globally installed Playwright browsers (chromium, firefox, webkit) and packages used by derived project images and the demo e2e runner |

The base image continues to publish `basecontainer-<flavor>-<arch>` tags (CPU and CUDA flavors). See
`documents/engineering/base_image.md` and `documents/engineering/warm_store.md`.

## optparse command tree projects extend

`hostbootstrap-core` exposes its subcommands as a composable optparse value plus the generic project
entrypoint `runHostBootstrapCLI progName projectSpec` (`HostBootstrap.CLI`, Phase 1; command tree in
`HostBootstrap.Command`, Phase 4; test suite hook from Phase 10; config-artifact registry from Phase 8).
The command surface is **fixed** for every binary — `project` / `test` / `service` / `context` /
`check-code` — and a project adds **no verbs**: `hostbootstrap-core` is a library of composable tools, not
a CLI topology (§ P). A project extends the core through `ProjectSpec` only — its lift chain, Dhall
vocabulary, schema-gen `ConfigArtifact` delta, non-empty test suite, service-handler registry, and required
`check-code` action; there are no `ProjectCommand` deltas. The entrypoint rejects empty project suites,
duplicate test cases, duplicate/shadowed artifacts, and duplicate service variants. The bare `hostbootstrap`
binary (`hostbootstrap-core`'s own executable) uses `runBareHostBootstrapCLI`, built like any project
binary rather than baked into the base image.
See
[development_plan_standards.md § P](development_plan_standards.md).

| Core verb group (target) | Phase | Implemented | Source |
|-----------------|-------|-------------|--------|
| `project init\|up\|down\|destroy` | 16 | yes | wired on the core tree; `up --dry-run` renders the chain through the gate (tested); effectful apply real-run-validated end-to-end; `down` stops VM frames and deletes kind clusters while preserving durable state; subsumes `config init`, `cluster`, `context create` |
| `context` (read-only introspection) | 15, 16 | yes | renders the composition from the sibling `<project>.dhall`; absorbs `config show\|schema\|render` |
| `test init\|run <suite\|all>` | 10, 17 | yes | `HostBootstrap.Harness` (`runSuiteSelection`/`runMatrix`); root-gated; `test run` drives the real `project up` under a test config with two fail-fast preconditions + `.test_data` (§ Z) |
| `service init\|schema\|run` | 18 | yes | long-running roles (`HostDaemon`/service run-model); `service run` is a leaf-frame pod entrypoint dispatched over a project-contributed `ServiceType` ADT; no `service down` (§ AA) |
| `check-code` | 10 | yes | required project-defined body supplied through `ProjectSpec`, the image-build gate |

The flat orchestration verbs (`config init`, `cluster up|down|delete|status`, `context create
vm|container|service`) are **removed** — `config init` -> `project init`, `cluster` ->
`project up|down|destroy`, `context create` -> the `context-init` chain step — and `config
show|schema|render|path` are folded into the read-only `context` command (recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Removed Surfaces`). The effectful
`project up` apply (recursive provisioning) is real-run-validated end-to-end on Incus/Linux and a 16 GiB
Apple-Silicon host (phase-16, phase-13).

## hostbootstrap-demo (worked consumer)

`hostbootstrap-demo` (Phase 13) is the self-contained worked consumer under `demo/` (runtime config
`hostbootstrap-demo.dhall`, Haskell source `demo/app/Main.hs` + `demo/src/HostBootstrapDemo/Commands.hs`,
build path `demo/.build`). It extends `hostbootstrap-core` directly (L0-direct) via
`runHostBootstrapCLI "hostbootstrap-demo" projectSpec` and demonstrates the extension streams — the lift
chain (`demoChain :: ProjectConfig -> [Step]` the core `project up` interprets; the former
`incus`/`vm`/`harbor`/`web` verbs collapse into chain steps and the `service` `Web` variant — phase-13/16/18),
the schema-gen concat (`config schema` / `config render --artifact demoWeb` over `coreArtifacts ++
demoArtifacts`), the harness (`hostbootstrap-demo test run all` → `runMatrix` driving the real `project up`
per test config, bound to the inherited `test` verb), and the service handlers (the demo's `Web` service
variant run by `service run`). The demo's runtime contexts are explicit sibling `hostbootstrap-demo.dhall`
files (host, VM, container on the VM, and cluster-service pod, the last delivered by a ConfigMap). The chain
drives the live surface — the provider-aware VM axis (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows), applied budget
cordons (VM = budget wall, cluster = slice), an idiomatic in-Dockerfile `check-code` gate
(`demo/docker/Dockerfile`), a `purescript-bridge`/`spago` webservice and SPA served by `service run`, and
Playwright e2e across all three browser engines (chromium, firefox, webkit) from the same project image that
inherits the base-provided browser runtime — centered on a from-zero pristine-host bootstrap inside a
managed Linux VM.

## Update rule

When the host-management architecture changes (a new `HostBootstrap.*` module, a new `ensure`
reconciler — including a host-provider like `incus`, a project-local-config field, a runtime-context
field or command-gating rule, a base-image or warm-store change — including a freeze-fragment split, a
new core command-tree verb, a new Python bootstrapper command such as `update`, a new run-model, or the
worked-consumer demo), update this inventory in the same change. Per
[development_plan_standards.md § F](development_plan_standards.md), this file is the single source of
truth for the host-management component set.
