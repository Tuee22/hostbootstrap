# Legacy Tracking for Deletion

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Current cleanup ledger for obsolete compatibility surfaces. `Pending` is the active
> cleanup list; `Removed Surfaces` records names that are intentionally absent from the supported
> architecture.

## Pending

These obsolete surfaces still exist and are tracked for removal by the unified-harness / fixed-surface /
resource-SSoT correction (development_plan_standards § W, § O, § P, § AA):

- **`vmSizingWithHeadroom` budget-doubling and the full-budget production cluster cordon**
  (`demo/src/HostBootstrapDemo/Commands.hs`) — `vmSizingWithHeadroom` adds a budget-sized headroom so the
  VM is sized to 2× the budget, and `deployKindAction` cordons the production kind cluster to the *full*
  budget; together they count the one ceiling twice. Replacement: the VM is sized to the budget (the VM
  wall) and the production cluster is cordoned to a slice within it (§ O). Owning phase: phase-13.
- **`demoSeams` inline bring-up mirror and the per-case cluster model**
  (`demo/src/HostBootstrapDemo/Commands.hs`) — `seamSetup`'s `clusterCreate caseResources` → `kind load` →
  `deployChart` re-implements the production `deploy-kind → push-image → deploy-chart` order, and
  `testCaseProfile` / `caseResources` stand up an isolated per-case cluster — a second cluster-bring-up
  representation beside the chain. Replacement: the harness drives the real `project up` (§ W). Owning
  phase: phase-10, phase-13.
- **The demo `vm` / `incus` / `web` project verbs and the `ProjectCommand` extension point**
  (`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`) — the
  command surface is fixed to `project` / `test` / `service` / `context` / `check-code`, and
  `hostbootstrap-core` is a library of composable tools, not a CLI topology (§ P). The IO is retained as
  library/step functions; only the verbs and the extension point are removed. Replacement: `vm`/`incus` IO
  → chain steps under `project up`; `web serve` → `service run` (`Web` variant, § AA); `web bridge` → the
  build-image step. Owning phase: phase-13, phase-16, phase-18.

## Retained Current Surfaces

These surfaces are intentionally present and are not cleanup obligations.

- **`hostbootstrap/prereqs.py`** — the Python host-prerequisite checks retained for the pre-binary
  bootstrapper. The fail-fast host minimums are the irreducible pre-binary subset (Linux: Ubuntu 24.04 +
  passwordless sudo, `linux-gpu` additionally the NVIDIA container runtime; Apple: passwordless sudo +
  Xcode CLT + Homebrew), dispatched by substrate alone. Richer host logic lives in Haskell
  `HostBootstrap.HostPrereqs` plus the `ensure` reconcilers.
- **Demo `web` / `vm` / `incus` verbs** — moved to **Pending** (above): the command surface is fixed to
  `project` / `test` / `service` / `context` / `check-code` (§ P), so these verbs are deleted. Their IO is
  retained as library/step functions the chain reuses (`runVmEnsure` / `runVmUp` / `runVmBootstrap`,
  `ensureIncus`); `web serve` → `service run` and `web bridge` → the build-image step.

## Removed Surfaces

These surfaces are not part of the current repository state. Reintroducing one is a regression unless
a plan update creates a new current owner for it.

- **Flat `config init` top-level verb** — config generation is now `project init`; the Python bootstrapper
  triggers `project init --if-missing` after the host-native build (the shared init parser is reused).
  Owning phase: phase-4.
- **Flat `cluster up|down|delete|status` top-level verb** — superseded by `project up` / `project down` /
  `project destroy`; the `clusterDown` / `clusterDelete` reconcilers remain, invoked by the lifecycle
  command. Owning phase: phase-4.
- **`context create vm|container|service` mutation verb** — superseded by the `context-init` chain step
  inside `project up`; the `context` command is now read-only introspection (`inspect` / `show` /
  `schema` / `render` / `path`), absorbing the former `config show|schema|render` inspection surfaces.
  Owning phase: phase-4.
- **Demo `deploy` / `harbor` / `role` verbs and the Op-based `HostBootstrapDemo.Chain`** — the demo has one
  canonical deploy: the contributed `demoChain :: ProjectConfig -> [Step]` value
  (`demo/src/HostBootstrapDemo/Commands.hs`) interpreted recursively by the core `project up`. The
  hand-written `demoDeployChain` / `renderPlan` / `runDeploy` module and the `deploy` (its interpreter),
  `harbor` (`runHarborInstall` / `runHarborPush` — now the chain's `deploy-harbor` / `push-image` steps), and
  `role` (`HostBootstrapDemo.Role`) verbs are deleted (2026-06-18); the demo does not maintain a second
  standalone deploy path beside `HostBootstrap.Harness`. Owning phase: phase-13, phase-16.
- **Dockerfile-baked `vm-project-container` runtime authority** — Dockerfiles now bake
  `image-build-container` authority only. Runtime workflows receive parent-mounted configs for the exact
  frame they run in.
- **Flat binary context without execution topology witnesses** — `HostBootstrap.Context` now encodes
  provider-backed frames, current-frame identity, parent links, and local runtime witnesses inside
  `<project>.dhall`.
- **Direct host/container fallback for VM-scoped kind workflows** — VM-project-container workflows require
  a VM-orchestrator ancestor and runtime witnesses before dispatch. Local smokes require an explicit local
  test-harness context.
- **Static-base Dhall fixtures** (`core/hostbootstrap-core/dhall/Type.dhall` and
  `core/hostbootstrap-core/dhall/example.dhall`) — the current schema is project-local
  `<project>.dhall`, decoded through `ProjectConfig`.
- **Python Dhall provisioning** (`hostbootstrap/dhall_tool.py`, `hostbootstrap/spec.py`, and
  `hostbootstrap/dhall/package.dhall`) — Python derives the project name from the Cabal file and never
  reads or writes Dhall.
- **Python host-context writer in `hostbootstrap/bootstrap.py`** — the built project binary owns
  sibling `<project>.dhall` initialization and child projection.
- **`StaticBase` compatibility API in `HostBootstrap.Config.Schema`** (`StaticBase`,
  `decodeStaticBaseText`, `decodeStaticBaseFile`, `renderStaticBase`) — the current API is
  `ProjectConfig`, `decodeProjectConfigText`/`File`, `renderProjectConfig`, `project init`, and the
  sibling `<project>.dhall` command gate.
- **`project-binary-context-config.dhall` artifact name** — host, VM, container, daemon, and service
  copies use the sibling `<project>.dhall` filename rule, with role/capability context inside the file.
- **`--create-container-config` Dockerfile shortcut** — container images create image-build config through
  `<project> project init --role image-build-container --output /usr/local/bin/<project>.dhall`; runtime
  contexts are parent-generated and mounted or materialized at launch.
- **`demo/hostbootstrap.dhall`** — the demo uses `hostbootstrap-demo.dhall` at each execution context.
- **`core/hostbootstrap-core/example/Main.hs` and the `hostbootstrap-example` executable** — the
  worked consumer is `demo/`.
- **Pre-binary container orchestration in `hostbootstrap/bootstrap.py`** — Python asserts host
  minimums, ensures the host build toolchain, builds the project binary host-native, initializes config
  if missing, and execs the binary. Docker ensure, container builds, VM sizing, and cluster operations
  belong to the project binary.
- **Legacy pipx `#egg=hostbootstrap` install/update specs** — downstream install and update guidance
  uses the direct VCS requirement form
  `hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main`. Reintroducing `#egg`
  fragments is a regression unless a future packaging plan makes them necessary again.
- **`pipx upgrade hostbootstrap` as the canonical update path** — the project currently has no
  versioned Python release channel, so self-update is a forced pipx reinstall from the canonical VCS
  source, not a version-based upgrade.
- **Automatic latest-version gating in normal Python commands** — `doctor`, `build`, `run`, and `base`
  do not auto-update, auto-check GitHub freshness, or fail merely because a newer wrapper commit exists.
  The update path is explicit.
- **Duplicate Python budget interpretation** (`_gib` and Python-side Colima sizing) — the canonical
  quantity parser and VM/container arg builders live in `HostBootstrap.Cluster.Cordon`.
- **`hostbootstrap/models/*`** (`container.py`, `host_binary.py`, `host_daemon.py`, `__init__.py`) —
  every project has one substrate-driven build/run path through `hostbootstrap/bootstrap.py`.
- **Three-execution-model Dhall schema** (`Container`/`HostBinary`/`HostDaemon`, `Cluster`/`NoCluster`,
  `Mount`, and target-selection fields) — project binaries own the current `ProjectConfig` schema.
- **Model dataclasses in `hostbootstrap/spec.py`** (`Model`, `Lifecycle`, `Mount`,
  `ContainerArtifact`, `ContainerModel`, `HostBinaryModel`, `HostDaemonModel`, `TargetSpec`,
  `ResolvedTarget`, `target_for`) — no model dispatch exists in the Python bootstrapper.
- **`--force-target` model dispatch in `hostbootstrap/cli.py`** — the Python CLI surface is
  `doctor` / `build` / `run` / `base`.
- **Python model/Dhall tests and fixtures** (`python/tests/test_models.py`,
  `python/tests/test_spec_dhall.py`, `python/tests/fixtures/dhall/*`) — the Python test suite covers
  the thin bootstrapper surface.
- **Hollow demo harness seams** (`demoSeams` without per-case assertions) — the demo uses real
  per-case seams (`assertClusterLive`, `assertWebBundle`, `assertE2E`) behind the standardized harness.
- **Demo `vm test` subcommand** — the inherited core `test` verb runs the project matrix through the
  `TestSuite` hook.
- **Non-substrate-aware off-Linux capacity fallbacks in
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`** — `readCores`'s unconditional
  single-core default and `readAvailableMemory`'s unconditional petabyte default when `/proc` was absent
  are removed. Replacement: substrate-aware `resolveHostCapacity` reads resolved `sysctl`
  `hw.ncpu` / `hw.memsize` on Apple silicon and retains `/proc/cpuinfo` plus `/proc/meminfo`
  `MemAvailable` on Linux.

## Rules

Per [development_plan_standards.md § I](development_plan_standards.md):

- If an obsolete or duplicate surface still exists, it must appear in the **Pending** section above.
  Each entry names its location, the reason for removal, and the owning phase or sprint.
- If a surface looks similar to a legacy cleanup item but is intentionally retained, it belongs in
  **Retained Current Surfaces**, not **Pending**.
- When cleanup lands, move the entry from **Pending** to **Removed Surfaces** in the same change.
- Empty `Pending` and `Removed Surfaces` sections are valid. The ledger exists as a stable home so
  cleanup obligations are never lost; absence of pending items reflects current reality, not an
  incomplete file.

## Entry format

When a future entry is added, use this shape:

```markdown
- `path/to/obsolete/file` — short reason for removal. Owning phase: phase-N.
```

For more complex entries:

```markdown
- **`path/to/obsolete/surface`** — reason for removal. Owning phase: phase-N, sprint X.Y.
  Replacement: `path/to/new/surface` (see `documents/...`).
```
