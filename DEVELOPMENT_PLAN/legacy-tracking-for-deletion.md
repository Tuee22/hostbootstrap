# Legacy Tracking for Deletion

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Current cleanup ledger for obsolete compatibility surfaces. `Pending` is the active
> cleanup list; `Removed Surfaces` records names that are intentionally absent from the supported
> architecture.

## Pending

No pending cleanup obligations. The generic-project-model correction
(development_plan_standards § BB) has **landed** (phase-19, 2026-06-23); its three former entries
moved to **Removed Surfaces** below. An empty `Pending` section is valid (see **Rules**).

## Retained Current Surfaces

These surfaces are intentionally present and are not cleanup obligations.

- **`hostbootstrap/prereqs.py`** — the Python host-prerequisite checks retained for the pre-binary
  bootstrapper. The fail-fast host minimums are the irreducible pre-binary subset (Linux: Ubuntu 24.04 +
  passwordless sudo + hardware virtualization (Intel VT-x / AMD-V plus a usable `/dev/kvm`), `linux-gpu`
  additionally the NVIDIA container runtime; Apple: passwordless sudo +
  Xcode CLT + Homebrew), dispatched by substrate alone. Richer host logic lives in Haskell
  `HostBootstrap.HostPrereqs` plus the `ensure` reconcilers.
- **Demo VM/provider chain-step IO** (`runVmEnsure` / `runVmUp` / `runVmBootstrap` /
  `ensureIncusProvider` in `demo/src/HostBootstrapDemo/Commands.hs`) — the IO that the dissolved `vm` /
  `incus` verbs used to expose is **retained as the metal chain's step actions** the core `project up`
  interprets. Only the verbs were removed (see **Removed Surfaces**), not the IO.
- **Demo web role + bridge IO** (`serveWeb` / `writeBridge`) — `serveWeb` is retained as the `web`
  'ServiceHandler' in `demoServices` (`service run web`), and `writeBridge` is retained as the bridge
  codegen the build-image chain step runs before the image build. Only the `web` verb was removed.

## Removed Surfaces

These surfaces are not part of the current repository state. Reintroducing one is a regression unless
a plan update creates a new current owner for it.

- **Core-owned config defaults** (`defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` in
  `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`, plus the `fromMaybe (cpu
  defaultResources)` / `value (memory defaultResources)` / `value (storage defaultResources)` flag
  defaults in `HostBootstrap.Command.initAction`) — removed 2026-06-23 by the phase-19 genericization.
  `hostbootstrap-core` owns **no** default config values: defaults live only in a project-owned `psInit`
  (`psInit :: InitArgs -> cfg`), which `project init` (layering optional flag overrides) and the harness
  both reuse. Owning phase: phase-19, sprint 19.1.
- **The fixed universal `ProjectConfig` / `Resources` / `DeployConfig` / `TestConfig` types as core types**
  (`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`) — removed 2026-06-23 by the phase-19
  genericization. Core owns no config type: `ProjectSpec` is parameterized as `ProjectSpec cfg tcfg`,
  coupled to a project's own config type only via `cfg -> BinaryContext` + `BinaryContext -> cfg -> cfg`
  (the `ProjectCfg`/`cfgContext` authority); the universal types became the demo's concrete `cfg`/`tcfg`.
  **Rejected alternative (recorded as rejected, not a cleanup obligation):** a core-owned generic
  `extra : Map Text Text` slot on a universal config type — rejected because core owns no project-specific
  field and no generic extra slot. Owning phase: phase-19, sprint 19.2.
- **The `test init` reads-existing-config / `test run` reuses-existing-config flow** (`runTestInit` in
  `HostBootstrap.Command` copying `resources cfg` from a pre-existing `<project>.dhall`; the demo's
  `demoTestUp` driving `project up` against that pre-existing config) — removed 2026-06-23 by the phase-19
  genericization. The harness now **generates** the run's `<project>.dhall` via the project-owned
  `psTestConfig` (reusing `psInit`, never shelling the CLI), runs the real `project up`, asserts, `project
  destroy`, then deletes the generated config and self-created `.test_data` (keeping `test.dhall`);
  `test init` requires no pre-existing `<project>.dhall`, the fail-fast existence precondition checks
  `siblingProjectConfigPath`, and a suite may declare more than one config variant. Owning phase: phase-19,
  sprint 19.3.
- **Flat `config init` top-level verb** — config generation is now `project init` (the shared init parser
  is reused). The Python bootstrapper does **not** trigger it: it builds the host-native binary and execs
  it, and the binary fails fast when no sibling `<project>.dhall` exists (the former post-build auto-init
  trigger is removed — see **The Python config auto-init trigger** below). Owning phase: phase-4.
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
- **The Python config auto-init trigger** (the post-build `project init --if-missing` in
  `hostbootstrap/bootstrap.py`) — the bootstrapper built the binary then triggered its idempotent config
  init so a default `<project>.dhall` always existed. Removed (2026-06-23, phase-19 sprint 19.5): Python
  builds the host-native binary and execs it; it does not initialize or trigger config creation, and a
  normal command fails fast (exit 1) when no sibling `<project>.dhall` exists — the config is created by an
  explicit `project init` or generated by the test harness (`psTestConfig`). Owning phase: phase-19,
  sprint 19.5.
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
  minimums, ensures the host build toolchain, builds the project binary host-native, and execs the
  binary; it does **not** initialize config (the binary fails fast when no sibling `<project>.dhall`
  exists — see **The Python config auto-init trigger** above). Docker ensure, container builds, VM
  sizing, and cluster operations belong to the project binary.
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
