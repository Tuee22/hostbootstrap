# Legacy Tracking for Deletion

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Current cleanup ledger for obsolete compatibility surfaces. `Pending` is the active
> cleanup list; `Removed Surfaces` records names that are intentionally absent from the supported
> architecture.

## Pending

- **Dockerfile-baked `vm-project-container` runtime authority** — the demo Dockerfile still bakes a
  runtime-capable container context at `/usr/local/bin/hostbootstrap-demo.dhall`. That is too permissive:
  image build/code-quality checks and lifted runtime workflows need distinct contexts. Owning phase:
  phase-15, sprint 15.6; phase-13, sprint 13.14. Replacement: `image-build-container` as the baked
  default, with parent-mounted runtime configs for lifted `test all`.
- **Flat binary context without execution topology witnesses** — `HostBootstrap.Context` currently gates
  by project/binary/context kind/capability/command class, but it does not yet encode provider-backed
  frames, current-frame identity, parent links, and local runtime witnesses. Owning phase: phase-15,
  sprint 15.6. Replacement: topology-aware `<project>.dhall` context.
- **Direct host/container fallback for VM-scoped kind workflows** — development runs can still invoke
  `test all` directly against the reachable Docker daemon. That must fail when the Dhall declares a VM
  project-container frame that is not witnessed locally. Owning phase: phase-13, sprint 13.14; phase-15,
  sprint 15.6. Replacement: explicit local test-harness context for local smokes, or parent-generated
  VM/container context for deploy.

## Retained Current Surfaces

These surfaces are intentionally present and are not cleanup obligations.

- **`hostbootstrap/prereqs.py`** — the Python host-prerequisite checks retained for the pre-binary
  bootstrapper. The fail-fast host minimums are the irreducible pre-binary subset (Linux: Ubuntu 24.04 +
  passwordless sudo, `linux-gpu` additionally the NVIDIA container runtime; Apple: passwordless sudo +
  Xcode CLT + Homebrew), dispatched by substrate alone. Richer host logic lives in Haskell
  `HostBootstrap.HostPrereqs` plus the `ensure` reconcilers.

## Removed Surfaces

These surfaces are not part of the current repository state. Reintroducing one is a regression unless
a plan update creates a new current owner for it.

- **Redundant demo deploy-chain representation** — the demo has one canonical deploy lift sequence in
  `demo/src/HostBootstrapDemo/Chain.hs`; it does not maintain a second standalone deploy path beside
  `HostBootstrap.Harness`.
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
  `ProjectConfig`, `decodeProjectConfigText`/`File`, `renderProjectConfig`, `config init`, and the
  sibling `<project>.dhall` command gate.
- **`project-binary-context-config.dhall` artifact name** — host, VM, container, daemon, and service
  copies use the sibling `<project>.dhall` filename rule, with role/capability context inside the file.
- **`--create-container-config` Dockerfile shortcut** — container images create role-specific config
  through `<project> config init --role vm-project-container --output /usr/local/bin/<project>.dhall`.
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
