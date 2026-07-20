# Legacy Tracking for Deletion

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Current cleanup ledger for obsolete compatibility surfaces. `Pending` is the active
> cleanup list; `Removed Surfaces` records names that are intentionally absent from the supported
> architecture.

## Pending

- **Demo hard-coded CPU base flavor for every project image** (`"basecontainer-cpu-" ++ arch` in
  `demo/src/HostBootstrapDemo/Commands.hs`) — pending replacement by substrate-aware base selection for the
  accelerator daemon demo. Linux CPU continues to use the CPU base, while Linux GPU daemon pods must use the
  CUDA base. Host-resident Apple/Windows daemon workers are not base-image flavors. Owning phases: phase-5
  Sprint 5.5 and phase-13 Sprint 13.17. Validation: Linux GPU integration test builds the CUDA worker from
  the CUDA base; Linux CPU integration test builds the C++ worker from the CPU base.
- **VM-only runtime project-container topology for cluster workflows** (`VMProjectContainer` requiring a
  `VMOrchestrator` ancestor in the binary-context gate) — pending generalization so the explicit Linux GPU
  accelerator topology can represent `host -> project container -> nvkind cluster` without an Incus VM,
  while the existing VM-backed container context remains strict. Owning phases: phase-15 Sprint 15.8 and
  phase-16 Sprint 16.5. Validation: context tests reject accidental direct host containers unless the
  Linux GPU direct topology is declared, and the Linux GPU integration test launches `nvkind` directly on
  the host.
- **`Capability.DurableStore` declared but never required** (`core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
  granted by `capabilitiesForKind` for `ClusterService` and `Daemon`, reflected into the golden
  `config_schema.dhall` and `dhall/example.dhall`) — pending wiring once the host-durable state surface lands.
  The capability is currently inert: no command's `requiredCapabilities` names it, so the membership gate in
  `validateContext` never consults it, and it must not be read as enforcement of any `.data` durability
  guarantee. Owning phases: phase-5 Sprint 5.6 (the durable-state surface) and phase-15 (the gate).
  Validation: a command gating on durable placement refuses a context that does not declare the capability.
- **The "host `.data`" framing and the `.data`-adjacent `§ O` citations** — retired in favour of the § Y
  removal-set wording plus the canonical home
  [durable_state](../documents/architecture/durable_state.md). `.data` is frame-relative, never
  host-mirrored on a lifted frame, and not survivable across `project destroy` of a provisioned frame; the
  invariant guarantees only that cluster teardown never enumerates the path for removal. `§ O` is
  "Resource Budget and Cordoning" and never owned this invariant — § Y does. Owning phases: phase-5
  (invariant owner) and phase-21 (the reconciliation). Validation: the mechanical documentation validator
  through `cabal test`, plus a grep floor asserting no `host \`.data\`` phrasing and no `.data`-adjacent
  `§ O` citation remains outside this ledger.
- **Web-only demo UI and service path as the final demo surface** — pending extension, not deletion of the
  web service. The current message/tab UI stays, but it is no longer sufficient as the final worked demo:
  the demo must add a real accelerator Add workflow whose result comes from daemon-returned backend/artifact
  metadata over CBOR WebSocket. Owning phase: phase-13 Sprint 13.17. Validation: browser e2e fills the two
  float inputs, clicks Add, and asserts the daemon-backed result.

The in-cluster-registry doctrine switch (Harbor → single-binary `registry:2`, phase-13 Sprint 13.16) was the
previous pending cleanup; it **closed 2026-07-05** on a live decoupled Windows/WSL2 `test run all` reporting
**`test report: 6/6 passed`** (`REALRUN_EXIT=0`) standing up `registry:2` and pushing the project image, so
its four Harbor surfaces **and** the removed `kind load registry:2` pre-load moved to **Removed Surfaces**
below.

The in-place child-config delivery correction (development_plan_standards § U, § X) landed in phase-15
Sprint 15.7 / phase-13 Sprint 13.15 (2026-07-02); its two former entries are in **Removed Surfaces** below.
The earlier generic-project-model correction (development_plan_standards § BB) landed in phase-19
(2026-06-23); its three former entries are in **Removed Surfaces** below.

## Retained Current Surfaces

These surfaces are intentionally present and are not cleanup obligations.

- **`hostbootstrap/prereqs.py`** — the Python host-prerequisite checks retained for the pre-binary
  bootstrapper. The fail-fast host minimums are the irreducible pre-binary subset (Linux: Ubuntu 24.04 +
  passwordless sudo — one floor for `build`/`doctor`/`run`, with `/dev/kvm` and the `linux-gpu` NVIDIA
  container runtime owned by the binary's `ensure incus` / `ensure cuda`; Apple: passwordless sudo +
  Xcode CLT + Homebrew), dispatched by substrate alone. Richer host logic lives in Haskell
  `HostBootstrap.HostPrereqs` plus the `ensure` reconcilers.
- **Demo VM/provider chain-step IO** (`runVmEnsure` / `runVmUp` / `runVmBootstrap` /
  `ensureIncusProvider` in `demo/src/HostBootstrapDemo/Commands.hs`) — the IO that the dissolved `vm` /
  `incus` verbs used to expose is **retained as the metal chain's step actions** the core `project up`
  interprets. Only the verbs were removed (see **Removed Surfaces**), not the IO.
- **Demo web role + bridge IO** (`serveWeb` / `writeBridge`) — `serveWeb` is retained as the `web`
  'ServiceHandler' in `demoServices` (selected by the config when `service run` starts), and `writeBridge` is retained as the bridge
  codegen the build-image chain step runs before the image build. Only the `web` verb was removed.
- **`core/hostbootstrap-core/dhall/example.dhall`** — retained as a live project-config fixture decoded
  by `SchemaSpec` and guarded against renderer drift. The reflected `context schema` /
  `config_schema.dhall` output is the schema source of truth; this fixture is an example value, not a
  hand-maintained type.

## Removed Surfaces

These surfaces are not part of the current repository state. Reintroducing one is a regression unless
a plan update creates a new current owner for it.

- **The 8-pod Harbor in-cluster registry and its dual-arch mirror** — the `harbor/harbor` Helm chart + its
  8-pod stack (`deployHarborAction`, `helm upgrade --install harbor`, NodePort 30500), the dual-arch
  `ghcr.io/octohelm/harbor/*:v2.14.0` override set (`harborImageOverrides`, pinning the chart to `1.18.3`),
  the trivy scanner override, and `harborAdminPassword` / `waitHarborLogin` (all in
  `demo/src/HostBootstrapDemo/Commands.hs`) — removed by the phase-13 Sprint 13.16 switch to a single-binary
  `registry:2` (CNCF `distribution`), which is natively multi-arch (no mirror), anonymous/insecure in-cluster
  (no admin password / login-wait), and ships no scanner. Replacement: `deployRegistryAction` applies a single
  `registry:2` Deployment + NodePort-30500 Service with `kubectl`. Owning phase: phase-13 Sprint 13.16 (step
  kind also phase-16); validated 2026-07-05 by a live Windows/WSL2 `test run all` **`6/6`** (`deploy-registry:
  in-cluster registry rollout complete`).
- **The `kind load docker-image registry:2` pre-load** (the `docker pull registryImage` + `runOrDie cfg Kind
  ["load", "docker-image", registryImage, …]` in `deployRegistryAction`) — removed 2026-07-05 because
  `kind load docker-image` (a `docker save` + `ctr import --all-platforms`) cannot import a **multi-arch**
  image (it fails `content digest … not found`), and `registry:2` publishes a multi-arch manifest.
  Replacement: the registry pod pulls `registry:2` itself (`imagePullPolicy: IfNotPresent`), so containerd on
  the node selects the node platform; the demo's own single-arch project image is still delivered locally by
  `push-image`'s `kind load`. Reintroducing the `kind load` of a multi-arch image is a regression. Owning
  phase: phase-13 Sprint 13.16; validated 2026-07-05 by the same `6/6` run (`push-image: kind-loaded … and
  pushed localhost:30500/…`).
- **Build-then-copy VM child config** (`writeAndCopyVMConfig` writing the host-side
  `demo/.build/hostbootstrap-demo.vm.dhall`, and `copyFileToDemoVM`, in
  `demo/src/HostBootstrapDemo/Commands.hs`) — removed 2026-07-02 by the in-place child-config delivery
  landing (development_plan_standards § U, § X). Replacement: `streamVMConfig` renders the narrowed VM
  projection and streams it over the VM shell's `stdin` (via `runInDemoVMStdin`), where the in-VM binary
  writes its own sibling `<project>.dhall`; no host-side `.vm.dhall` is written. `copyFileToDemoVM` is
  deleted (`stageSource` uses `stageFileEffects` directly — **retained**). Owning phase: phase-13
  Sprint 13.15, phase-15 Sprint 15.7; validated 2026-07-02 by `cabal test all` (280) and a live
  Windows/WSL2 `test run all` `6/6` (the `streamed parent-derived VM config …` marker; no `.vm.dhall`
  produced).
- **Build-then-mount container child config** (`mintContainerConfig` + `vmRuntimeContainerConfigPath`
  writing `hostbootstrap-demo.runtime-container.dhall`, and the config `Mount` in `demoDeployImage`
  bind-mounting it over `/usr/local/bin/hostbootstrap-demo.dhall`, in
  `demo/src/HostBootstrapDemo/Commands.hs`) — removed 2026-07-02. Replacement: `containerConfigPayload`
  renders the narrowed projection, folded into `demoDeployImage`'s `clConfigDelivery` and streamed on the
  container handoff `stdin` (core `HostBootstrap.Lift.ConfigDelivery` + the `HostBootstrap.Chain`
  `liftStdin`/`liftSubcommandWithStdin` handoff), with an entrypoint wrapper
  (`sh -c 'cat > <sibling> && exec <pb> project up'`) writing the sibling before dispatch; the docker-socket
  and `/run/hostbootstrap` witness mounts are **retained**. `mintContainerConfig` is now
  `contextInitAnnounce` (a frame anchor keeping `vm-orchestrator-1` a real frame). Owning phase: phase-13
  Sprint 13.15, phase-15 Sprint 15.7; validated 2026-07-02 by `cabal test all` (280, incl. `LiftSpec`
  config-delivery cases asserting the projection is absent from `argv`) and a live Windows/WSL2
  `test run all` `6/6` (no `-v …hostbootstrap-demo.dhall` on the container `docker run`).

- **The hand-branched `DemoVMProvider` sum and its per-substrate lifecycle branches**
  (`data DemoVMProvider = AppleLimaVM | LinuxIncusVM | WindowsWsl2VM`, `demoVMProvider`, `demoVMName`, and
  the `case provider of` arms in `runVmUp` / `demoTeardown` / `stageSource` / `copyFileToDemoVM` /
  `runInDemoVMStdin` plus the duplicate substrate guard in `demoVMFrameContext`, all in
  `demo/src/HostBootstrapDemo/Commands.hs`; and the `limaInstanceExists` / `incusInstanceExists` /
  `wsl2DistroExists` / `waitVMAgent` / `waitLimaVM` / `waitWsl2VM` helpers) — removed when the per-substrate
  VM lifecycle was unified behind one pure lift. Replacement: `HostBootstrap.Substrate.Provider`
  (`SubstrateProvider`, `selectSubstrateProvider`, the `HostEffect` launch list, and the generic demo
  interpreters `demoProvider` / `substrateExists` / `substrateWait` / `runEffects`). The chain-step IO
  (`runVmUp` etc.) is **retained** (see **Retained Current Surfaces**); only the hand-branched dispatch was
  removed. Owning phase: phase-9, sprint 9.7; validated 2026-06-30 by `cabal test all` (274 tests, incl.
  `ProviderSpec` byte-for-byte Lima/Incus equivalence) and the demo binary build.
- **The volatile Windows memory-capacity predicate** (`WindowsAvailableMemory` `CapacityReadSource`
  reading `Win32_OperatingSystem.FreePhysicalMemory` in
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`) — removed because momentary free RAM let
  the preflight pass on transient post-reboot memory and an undersized host reach the build. Replacement:
  `WindowsTotalMemory` reading stable `Win32_ComputerSystem.TotalPhysicalMemory` (mirroring Apple
  `hw.memsize`). Owning phase: phase-9, sprint 9.7; validated 2026-06-30 by `cabal test all` (`CordonSpec`).
- **The `vhdx-size` line in the WSL2 `.wslconfig` body** (the `"vhdx-size=…GB"` element formerly emitted by
  `wsl2SizingArgs` in `Cordon.hs`) — removed because `.wslconfig` `[wsl2]` has no `vhdx-size` key; the
  per-distro VHDX cap is the `wsl --install --vhd-size` flag. Replacement: the `[wsl2]` body now emits
  `processors`/`memory`/`swap` (swap for OOM headroom) and the storage cap rides the install argv. Owning
  phase: phase-9, sprint 9.7; validated 2026-06-30 by `cabal test all` (`CordonSpec`).
- **The `ensure-tart` reconciler and `HostBootstrap.Ensure.Tart` module** (`core/hostbootstrap-core/src/HostBootstrap/Ensure/Tart.hs`; the `Tart` import + `allReconcilers` entry in `Command.hs`; the `Tart` constructor + `toolCommandName Tart = "tart"` in `HostTool.hs`; the exposed-module in `hostbootstrap-core.cabal`; the import + reconciler-name + `appliesTo` + `installSteps` cases in `test/EnsureSpec.hs`; the `Tart` entry in `test/HostToolSpec.hs`) — removed when Windows joined as the third metal substrate and the headless host-build pattern replaced Tart's build-VM shape. Tart was core-only and latent. Replacement: the `ensure-cudawin` reconciler. Owning phase: phase-3, sprint 3.5; validated 2026-06-26 by `cabal build all` and `cabal test all`.
- **Composition pattern #7 as a build-only VM (the `ensure tart` shape)** — removed by the phase-3
  re-anchoring. Replacement: pattern #7 "Headless host build for platform-locked artifacts" — build on the
  bare host, stage into the cluster through the project chain, never run the workload in a VM — with
  CUDA-on-Windows (`ensure-cudawin`) as its first worked instance. Owning phase: phase-3, sprint 3.5;
  validated 2026-06-26 by `cabal build all` and `cabal test all`.
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
  destroy`, then deletes matching run-owned config bytes and self-created `.test_data` (keeping
  `test.dhall`); changed config bytes remain in the reported locked quarantine;
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
- **Standalone `ensure <tool>` top-level command** — removed by the
  [Phase 21](phase-21-documentation-code-consistency-reconciliation.md) command-surface reconciliation.
  `ensure` is a library of idempotent reconciler primitives composed as `ensure-*` chain steps; the fixed
  user-facing command surface is `project`, `test`, `service`, `context`, and `check-code`, with no hidden
  commands. Owning phase: phase-3.
- **Demo `deploy` / `harbor` / `role` verbs and the Op-based `HostBootstrapDemo.Chain`** — the demo has one
  canonical deploy: the contributed `demoChain :: ProjectConfig -> [Step]` value
  (`demo/src/HostBootstrapDemo/Commands.hs`) interpreted recursively by the core `project up`. The
  hand-written `demoDeployChain` / `renderPlan` / `runDeploy` module and the `deploy` (its interpreter),
  `harbor` (`runHarborInstall` / `runHarborPush` — now the chain's `deploy-harbor` / `push-image` steps), and
  `role` (`HostBootstrapDemo.Role`) verbs are deleted (2026-06-18); the demo does not maintain a second
  standalone deploy path beside `HostBootstrap.Harness`. Owning phase: phase-13, phase-16.
- **Dockerfile-baked `vm-project-container` runtime authority** — Dockerfiles now bake
  `image-build-container` authority only. Runtime workflows receive parent-generated configs streamed
  in-place for the exact frame they run in (§ X).
- **Flat binary context without execution topology witnesses** — `HostBootstrap.Context` now encodes
  provider-backed frames, current-frame identity, parent links, and local runtime witnesses inside
  `<project>.dhall`.
- **Direct host/container fallback for VM-scoped kind workflows** — VM-project-container workflows require
  a VM-orchestrator ancestor and runtime witnesses before dispatch. Local smokes require an explicit local
  test-harness context.
- **`core/hostbootstrap-core/dhall/Type.dhall`** — deleted by
  [Phase 21](phase-21-documentation-code-consistency-reconciliation.md). The reflected `context schema` /
  `config_schema.dhall` output is the schema source of truth; a hand-maintained type file only drifts.
  Owning phase: phase-8.
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
  contexts are parent-generated and streamed in-place at launch (§ X), except the Kubernetes service pod,
  whose config arrives as a ConfigMap override.
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
- **The `GenerousStorage` (1 PB) capacity source in
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`** — the unconditional petabyte free-storage
  reading for Apple/Linux (which made the storage preflight a no-op off Windows) is removed. Replacement:
  `PosixFreeStorage "/"` read via a real `df -P -k` (the new `Df` host tool + the pure
  `parseDfAvailableKBytes`), so the storage ring gates on real free disk on all three substrates. Owning
  phase: phase-9 (reopened 2026-07-05); validated by `cabal test all` (`CordonSpec` — the `df` parser and the
  Apple/Linux `PosixFreeStorage` read plan).
- **The full-file `WriteHostFile` clobber of the global `.wslconfig`** (the WSL2 launch effect in
  `HostBootstrap.Substrate.Provider` and its `writeHostFileWithBackup` interpreter overwriting the whole
  `.wslconfig`) — removed for the WSL2 cordon. Replacement: the `MergeWslConfig` effect + pure
  `HostBootstrap.Wsl2.mergeWslConfig`, which drops only the old `[wsl2]` section and appends ours, preserving
  the user's other sections (never-clobber-user-state). Owning phase: phase-9 (reopened 2026-07-05);
  validated by `cabal test all` (`Wsl2Spec` merge cases, `ProviderSpec` launch effect list). `WriteHostFile`
  itself is retained for any future whole-file host write.

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
