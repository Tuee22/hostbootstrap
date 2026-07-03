# Phase 11: incus First-Class Host-Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)

> **Purpose**: Add VM providers as first-class host-provider axes so anything `hostbootstrap` deploys on
> an unvirtualized linux host it can deploy inside a managed Linux VM, with the same machinery and the
> same budget cordon. Native Linux uses Incus; Apple Silicon uses a Lima VM for the worked demo; Windows
> uses a WSL2 Ubuntu-24.04 distro.

## Phase Status

**Status**: Done

`incus` is the native Linux host-provider axis. `HostTool` includes the `Incus` constructor (resolved to an `AbsExe`
like every host tool); `HostBootstrap.Ensure.Incus` is a cross-substrate install-and-verify reconciler
(Colima-backed Incus runtime on Apple, native daemon on Linux); `HostBootstrap.HostTarget`
parameterizes linux-host operations by `HostTarget = Local | InVM IncusVM`; `HostBootstrap.Incus`
carries the VM lifecycle argv and `classifyDockerReadiness`; and `incusSizingArgs` uses the canonical
quantity parser to cordon the VM at the wall
(`limits.cpu`/`limits.memory`/`root,size`). `incus` is not a substrate and not a fifth run-model; it is a
supported host-provider layer. The **Windows** host-provider peer is **WSL2** — a budget-sized Ubuntu-24.04
distro reached by `wsl -d <distro> -- …`, the structural peer of the Incus (native Linux) and Lima (Apple
Silicon) VM providers: Docker, kind, and the workload run **inside the distro** exactly as they do inside
the Lima/Incus VMs (Sprint 11.7).

`HostBootstrap.Lift` is the subcommand-level self-reference lift. It generalizes the two-case
`HostTarget = Local | InVM` tool-level lift to an n-level context stack (`Local`, provider-backed `InVM`,
`InContainer`)
so a binary crosses any boundary by invoking its own subcommand in the nested context. The pure cores,
argv builders, dispatch, and lift fold are unit-tested, and the worked demo exercises the in-VM and
in-container path in real runs.

This phase is reopened because Apple Silicon should not rely on an Incus VM inside the Colima Incus
runtime for the demo VM. The supported Apple path is a Lima VM reached by `limactl shell
hostbootstrap-demo-vm -- ...`, while native Linux keeps the Incus VM path. The pure Lima argv builder,
`ensure lima`, and lift fold are implemented and validated through the full demo lifecycle.

This phase is **reopened** again for the **Windows** host-provider peer. WSL2 is the Windows peer of Lima
(Apple Silicon) and Incus (native Linux): a fresh Ubuntu-24.04 distro reached by `wsl -d <distro> -- …`,
sized to the budget wall (the `wsl2SizingArgs` `.wslconfig` + vhdx cap from
[phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)), running Docker +
kind + the workload inside the distro exactly as the Lima/Incus VMs do. `HostBootstrap.Wsl2` carries the
pure argv builders and the host-reboot readiness classifier `classifyWsl2Readiness`,
`HostBootstrap.Ensure.Wsl2` exposes `ensure wsl2` (windows-cpu + windows-gpu), and `HostBootstrap.Lift`
folds a provider-backed VM layer through WSL2 into the distro (`wsl -d <distro> -- <inner>`). That is
Sprint 11.7 (`[Done]`), which also carried the Windows/WSL2 demo real-run validation — **closed 2026-07-01**
by a full `project up` → `test run all` (`6/6`) → `project destroy` Windows lifecycle with the `.wslconfig`
ceiling applied.

## Remaining Work

None. The **Windows WSL2 host provider** is implemented, unit-validated, and now **real-run-closed
(2026-07-01)**. The post-reboot WSL2 platform readiness gate was crossed on 2026-06-29
(`HyperVisorPresent = True`, `VirtualizationFirmwareEnabled = True`, default WSL version 2), and the full
Windows lifecycle then closed end to end: a live `hostbootstrap-demo` `test run all` **applied the
`.wslconfig` `[wsl2]` ceiling** (Sprint 9.7's honest cordon — the fix for the earlier
`Wsl/Service/0x80072746` utility-VM session drop, whose root cause was the cordon being computed but never
written), registered/entered the managed `hostbootstrap-demo-vm` Ubuntu-24.04 distro, staged the source,
built the in-distro host-native binary (build #2) and the project container (build #3, in-Dockerfile
`fourmolu`/`hlint`/`cabal -Werror` gate passing) **without a session drop**, stood up in-distro
kind/Harbor/web on the VM's Docker, ran the lifted project-container assertions, and reported
**`test report: 6/6 passed`** across both message variants — then `project destroy` tore the stack down
through the guarded `wsl --unregister` path, restoring `.wslconfig` with host `.data` preserved. Native
Linux remains the Incus provider path and Apple Silicon uses Lima; WSL2 is the validated Windows peer.

Static validation is clean: `cabal test all` and `cabal build all --ghc-options=-Werror` from `core/`,
`cabal test all` from `demo/` (demo suite plus the embedded core suite), `cabal build all
--ghc-options=-Werror` from `demo/`, and `poetry run python -m hostbootstrap.check_code`.

## Phase Objective

Land the host-provider axis: the `ensure incus` install-and-verify reconciler, the `HostTarget` dispatch,
the VM lifecycle, the reboot-to-ready reconcile, and the budget-sized VM, such that every linux-host
operation runs against `Local` or `InVM` with no per-call branching.

## Sprints

### Sprint 11.1: `HostTool Incus` and `ensure incus` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Add the `HostTool Incus` constructor and the `ensure incus` install-and-verify reconciler, wired into
the reconciler list so the host `incus` resolves to an `AbsExe` across apple-silicon and linux.

#### Reconciler Contract

- `ensure incus` `appliesTo = isAppleSilicon || isLinux` (the first cross-substrate reconciler).
- Install-and-verify: on apple-silicon, `brew install incus`, `brew install colima`, and
  `colima start incus --runtime incus` (precondition `ensure homebrew`); on ubuntu-24.04,
  `sudo apt-get install -y incus` + `sudo incus admin init --minimal`; on linux it also adds the
  invoking non-root user to `incus-admin` so future sessions can reach the daemon socket.
  Probe-first/idempotent; fail-fast on a genuinely unsupported host.

#### Deliverables

- `HostTool` gains the `Incus` constructor (`toolCommandName Incus = "incus"`); the host `incus` resolves
  to an `AbsExe`. `HostBootstrap.Ensure.Incus` wired into the reconciler list.

#### Validation

- `EnsureSpec` asserts incus applicability (apple + linux), idempotent no-op when present, and fail-fast on
  an unsupported host. `cabal test` passes.

#### Remaining Work

None.

### Sprint 11.2: `HostTarget` and the incus driver [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTarget.hs`, `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`, `core/hostbootstrap-core/test/IncusSpec.hs`
**Docs to update**: `documents/architecture/build_and_run_model.md`, `documents/architecture/run_models.md`

#### Objective

Land the typed target abstraction and the VM lifecycle.

#### Deliverables

- `data HostTarget = Local | InVM IncusVM`; `runInTarget cfg Local t args = runTool cfg t args`;
  `runInTarget cfg (InVM vm) t args = execVM …` (`incus exec <name> -- <cmd>`).
- VM lifecycle through the resolved host `incus`: `createVM`, `start`/`stop`, `execVM`, `pushFiles`
  (`incus file push`), `rebootVM`, `destroyVM` (name-prefix delete-guarded, reusing the harness
  `guardTestDelete` idiom). The in-VM tool is the VM's own PATH binary reached through the single host
  `incus exec` (§ K governs host invocation only).

#### Validation

- A test asserts `runInTarget Local` reuses `runTool` and the `InVM` path builds the `incus exec` argv;
  `destroyVM` refuses a non-prefixed name.

#### Remaining Work

None.

### Sprint 11.3: Reboot-to-ready reconcile [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Incus.hs` (`classifyDockerReadiness`), `core/hostbootstrap-core/src/HostBootstrap/HostTarget.hs` (`rebootDockerToReady`), `core/hostbootstrap-core/test/IncusSpec.hs`
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Ensure Docker on a fresh VM, rebooting if the install needs it.

#### Deliverables

- Pure `classifyDockerReadiness :: (ExitCode, String, String) -> Ready | NeedsReboot | Unsatisfiable`.
- An IO loop that installs Docker in the VM, probes `docker info`, reboots (`incus restart`) + waits for
  the guest agent (bounded), and resumes on `NeedsReboot`; fails fast otherwise.

#### Validation

- A pure spec covers the `classifyDockerReadiness` branches; the loop is bounded by `maxReboots`.

#### Remaining Work

None.

### Sprint 11.4: `incusSizingArgs` and the in-VM deployment path [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/src/HostBootstrap/HostTarget.hs`, `core/hostbootstrap-core/test/IncusSpec.hs`
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Cordon the VM to the budget and run the full deployment surface inside it.

#### Deliverables

- `incusSizingArgs :: Resources -> Either String [String]` (from the one canonical parser) sizing the VM
  (`limits.cpu`, `limits.memory`, `root,size` — incus cordons storage at the VM wall, unlike
  `docker update`). The build / ensure-docker / kind / harbor / run / harness machinery runs against an
  `InVM` target unchanged.

#### Validation

- `CordonSpec` asserts `incusSizingArgs` reflect the declared budget byte-for-byte.

#### Remaining Work

None. `incusSizingArgs` and the `InVM` target path are implemented and unit-tested. GPU passthrough
(`linux-gpu` inside an incus VM, CUDA/nvkind) and apple-silicon nested virtualization are outside this
phase.

### Sprint 11.5: The self-reference lift (`HostBootstrap.Lift`) [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/test/LiftSpec.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/incus.md`, `system-components.md`

#### Objective

Generalize the host-provider axis from the two-case `HostTarget` (tool-level lift) to the n-level
subcommand-level **self-reference lift**: a binary crosses a context boundary by re-invoking its own
subcommand in the nested context (selected VM provider for a VM, `docker run --rm` for a container whose
`ENTRYPOINT` is the binary).

#### Deliverables

- `HostBootstrap.Lift`: `LiftContext` (a stack of `ViaVM`/`ViaContainer` layers with `inVM`/`inContainer`
  builders), `SelfRef` (binary identity, separate from `HostConfig`), the pure
  `foldLift :: SelfRef -> LiftContext -> [String] -> LiftDispatch`, and the `liftSubcommand` IO seam
  (reusing `runTool`; a new `runSelf` for the binary itself). `HostTarget`/`runInTarget` are kept
  alongside as the narrower tool-level lift.
- The argv fold honors § K (absolute tool only at the outermost host hop; bare `$PATH` names nested) and
  the container `ENTRYPOINT`-is-the-binary contract; a `VM`-then-`Container` stack folds through the
  selected VM provider, then `docker run --rm <image> <subcmd>`.

#### Validation

- `LiftSpec` asserts the pure fold for `Local`, `InVM`, `InContainer`, and `VM`-then-`Container` nesting,
  plus the container argv builder. `cabal test` passes.

#### Remaining Work

None. The lift primitive and its `LiftSpec` tests are implemented, and the demo composes it.

### Sprint 11.6: Lima VM provider for Apple Silicon [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Lima.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Chain.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/operations/demo_runbook.md`, `system-components.md`

#### Objective

Make the VM provider selected by substrate: Lima on Apple Silicon, native Incus on Linux. The
demo must not attempt to create an Incus VM on Apple Silicon.

#### Deliverables

- `HostBootstrap.Lima` with pure argv builders for `limactl start`, `limactl shell`, `limactl copy`,
  `limactl list`, and guarded `limactl delete`. The start builder disables Lima-managed containerd
  because Docker is reconciled by the project binary inside the pristine VM.
- `HostBootstrap.Ensure.Lima` exposes `ensure lima` as the Apple-only install-and-verify reconciler.
- `HostBootstrap.Lift` can fold a provider-backed VM layer through Lima as well as Incus.
- `demo vm ensure`, `vm up`, `vm pristine-bootstrap`, `deploy`, and `vm down` select Lima on Apple
  Silicon and Incus on Linux.
- The demo dry-run prints the selected provider fold, e.g.
  `limactl shell hostbootstrap-demo-vm -- docker run --rm ... test all` on Apple Silicon.

#### Validation

- `cabal build all` from `core/` passes.
- `cabal build all` from `demo/` passes.
- `hostbootstrap run --project-root demo deploy --dry-run` on Apple Silicon prints the Lima lift rather
  than an Incus lift.
- `hostbootstrap run --project-root demo deploy` on Apple Silicon passed end to end: it created the Lima
  VM with the documented budget, ran the in-VM bootstrap and image build, lifted the project-container
  `test all`, reported `test report: 3/3 passed` including `e2e-tabs`, and destroyed the VM.

#### Remaining Work

None.

### Sprint 11.7: Windows WSL2 host provider [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs` (the `Wsl` constructor),
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/Wsl2Spec.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`, `core/hostbootstrap-core/test/LiftSpec.hs`
**Docs to update**: `documents/engineering/wsl2.md`, `documents/engineering/incus.md`,
`documents/engineering/lima.md`, `documents/operations/demo_runbook.md`, `system-components.md`

#### Objective

Land **WSL2** as the Windows host-provider peer of Lima (Apple Silicon) and Incus (native Linux): the pure
WSL2 lifecycle argv builders, the host-reboot readiness classifier, `ensure wsl2`, and the
`HostBootstrap.Lift` fold into a fresh Ubuntu-24.04 distro, so every windows-host operation runs against
`Local` or the WSL2-backed `InVM` with no per-call branching.

#### Reconciler Contract

- `ensure wsl2` `appliesTo = isWindowsCpu || isWindowsGpu` (applies on windows-cpu **and** windows-gpu);
  install-and-verify the WSL2 Ubuntu-24.04 distro, probe-first/idempotent. A run on a non-Windows host
  fails fast with the one-line wrong-host diagnostic (§ L).
- Firmware virtualization is a Phase 2 host-floor fact: if disabled, `ensure wsl2` reports
  `Unsatisfiable` because a project binary cannot change BIOS/UEFI state. Windows OS virtualization
  readiness is Phase 11 `ensure wsl2` work: enable the WSL/VMP features, install/update `Microsoft.WSL`,
  ensure the Windows hypervisor is configured to launch (`hypervisorlaunchtype auto` or equivalent
  verified state), and return `NeedsReboot` after any feature or boot-state change.
- `classifyWsl2Readiness :: (ExitCode, String, String) -> Ready | NeedsReboot | Unsatisfiable` is the
  host-reboot verdict — the structural peer of the Incus `classifyDockerReadiness` `NeedsReboot`
  (Sprint 11.3); a fresh `wsl --install` requiring a host reboot is classified `NeedsReboot` so the caller
  surfaces the reboot instruction rather than proceeding.

#### Deliverables

- `HostBootstrap.Wsl2`: the pure argv builders `wsl --import <distro> <dir> <tarball>`,
  `wsl -d <distro> -- <inner>`, `wsl --terminate <distro>`, `wsl --shutdown`, and the name-prefix
  delete-guarded `wsl --unregister <distro>` (the guarded destroy, reusing the harness `guardTestDelete`
  idiom), plus `classifyWsl2Readiness`. The distro is sized to the budget wall by `wsl2SizingArgs`, the
  pure builder [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md) owns:
  the **global** `.wslconfig` `[wsl2]` `processors`/`memory`/`swap` utility-VM ceiling (WSL2 has no
  per-distro `wsl --memory`/`--cpu`) plus the per-distro `wsl --install --vhd-size` storage cap.
- **The applied WSL2 wall (honest cordon, Sprint 9.7).** Bring-up writes the `.wslconfig` ceiling and runs
  `wsl --shutdown` to apply it before registering the distro; this is consumed as the unified
  `HostBootstrap.Substrate.Provider.spLaunch` effect list (the one pure lift per substrate), and
  `project destroy` restores the backed-up `.wslconfig`. The demo's VM lifecycle
  (`runVmUp`/`demoTeardown`/`stageSource`/`copyFileToDemoVM`/`demoVMFrameContext`) is interpreted
  generically over that provider value, no longer hand-branched per substrate.
- `HostBootstrap.Ensure.Wsl2` exposes `ensure wsl2` as the windows-cpu + windows-gpu install-and-verify
  reconciler, wired into `allReconcilers`; readiness is WSL2 platform readiness (`wsl --status` without a
  virtualization-disabled diagnostic), while project-owned VM bring-up registers the named Ubuntu-24.04
  distro. The install plan installs the `Microsoft.WSL` winget package, runs `wsl --install
  --no-distribution`, sets WSL default version 2, and reconciles Windows hypervisor launch state before
  re-probing. `HostTool` gains the `Wsl` constructor (`toolCommandName Wsl =
  "wsl"`) resolved to an `AbsExe`; on Windows it resolves the System32 executable before the WindowsApps
  alias.
- `HostBootstrap.Lift` folds a provider-backed VM layer through WSL2 into the Ubuntu-24.04 distro
  (`wsl -d <distro> -- <inner>`), so a `VM`-then-`Container` stack on Windows folds to
  `wsl -d <distro> -- docker run --rm <image> <subcmd>` — Docker + kind + the workload run **inside the
  distro**, exactly as Lima/Incus. The in-distro tool is the distro's own `$PATH` binary reached through
  the single host `wsl -d` (§ K governs host invocation only).
- The demo's chain selects WSL2 on `windows-cpu`/`windows-gpu`: `runVmEnsure` runs `ensure wsl2`,
  `runVmUp` composes the managed distro name from the project identity (`<project>-vm`, currently
  `hostbootstrap-demo-vm`) and registers it if absent, `demoFrameContext` hands off through `inWsl2VM`,
  source/config staging uses the distro's `/mnt/<drive>/...` view of host files, and `project destroy`
  uses the name-prefix-guarded `wsl --unregister` builder.
- **Registry credential forwarding on Windows (operator prerequisite, no new code).** Symmetric with the
  other substrates: with the **standalone Docker CLI** (`docker.exe`, no Docker Desktop) and `docker login`
  (a Docker Hub PAT, no credential helper), the inline token in `%USERPROFILE%\.docker\config.json` is
  discovered by `discoverHostRegistryAuth` and forwarded over the existing WSL2 stdin tunnel into build
  #3's base pull — removing the anonymous rate-limit risk during the Windows lifecycle closure. This
  reuses the existing forwarding rails unchanged; see
  [registry_credentials.md](../documents/engineering/registry_credentials.md) and the
  [demo runbook](../documents/operations/demo_runbook.md) Windows/WSL2 note.

#### Validation

- `Wsl2Spec` asserts the pure `wsl --import` / `wsl -d <distro> --` / `wsl --terminate` / `wsl --shutdown`
  argv, the name-prefix-guarded `wsl --unregister` (refusing a non-prefixed distro), and the
  `classifyWsl2Readiness` branches; `EnsureSpec` asserts `wsl2` applicability (windows-cpu + windows-gpu)
  and wrong-host fail-fast; `LiftSpec` covers the WSL2 VM fold; `HostToolSpec` covers the `Wsl` constructor.
  `cabal test all` passes.
- 2026-06-26 live Windows validation: after Phase 2 supplied GHC/Cabal, `cabal build all` and
  `cabal test all` passed from `core/`. A live `runEnsure HostBootstrap.Ensure.Wsl2.reconciler` enabled
  the Windows WSL/VMP features, installed `Microsoft.WSL` 2.7.8, and then failed closed with
  `ensure wsl2: host reboot required after WSL2 install; reboot and retry`. `HostToolSpec` covers the
  System32 WSL resolution path so the reconciler does not hit the WindowsApps alias first.
- 2026-06-27 code validation: `cabal test all` passed from `core/` with the explicit GHCup toolchain
  environment (`All 252 tests passed`), and `cabal build all --ghc-options=-Werror` passed. `Wsl2Spec`
  now covers both the allowed and refused branches of the name-prefix-guarded `wsl --unregister` builder.
- 2026-06-27 real-provider probe: `C:\Windows\System32\wsl.exe --status` reports default WSL version 2
  and still prints a WSL2 startup diagnostic saying virtualization is not enabled, but independent host
  checks disagree: `systeminfo.exe` reports `Virtualization Enabled In Firmware: Yes`,
  `Win32_Processor.VirtualizationFirmwareEnabled` is `True`, and DISM reports both
  `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` as `Enabled`. `wsl.exe --list --verbose`
  reports no installed distributions before the project chain runs.
- 2026-06-27 code validation after Windows-provider wiring: the demo chain selects WSL2 on Windows and
  owns project-named distro registration / WSL2 handoff / guarded teardown, `Wsl2VMProvider` is in the context schema, `cabal test all` passes from
  `core/` (`All 252 tests passed`), `cabal test all` passes from `demo/` (demo `14/14` plus embedded core
  `252/252`), both `cabal build all --ghc-options=-Werror` gates pass, and a generated sibling
  `hostbootstrap-demo.dhall` dry run of the built `hostbootstrap-demo.exe project up --dry-run` renders the
  nine-step chain with the provider step labeled `Lima on Apple Silicon, Incus on Linux, WSL2 on Windows`.
- 2026-06-27 live binary-owned provider validation: a generated sibling `hostbootstrap-demo.dhall` plus
  built `hostbootstrap-demo.exe project up` reached the first chain step, ran `ensure wsl2`, and failed
  closed with `ensure wsl2: host reboot required after WSL2 install; reboot and retry`. Independent host
  checks still report firmware virtualization support (`Virtualization Enabled In Firmware: Yes`,
  `Win32_Processor.VirtualizationFirmwareEnabled = True`, VM monitor mode extensions and SLAT present),
  and `wsl.exe --list --online` lists `Ubuntu-24.04` as installable. The generated sibling config was
  removed after the blocked run.
- 2026-06-28 blocked-provider probe: `C:\Windows\System32\wsl.exe --status` reports default WSL version 2
  but still prints the WSL2 startup diagnostic saying virtualization is not enabled; `wsl.exe --list
  --verbose` reports no installed distributions. A follow-up host probe shows this is not a firmware
  virtualization failure: `systeminfo.exe` reports `Virtualization Enabled In Firmware: Yes`,
  `Win32_Processor.VirtualizationFirmwareEnabled = True`, VM monitor extensions and SLAT are present,
  DISM reports `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` as `Enabled`, but
  `HyperVisorPresent = False` and `bcdedit` does not report an explicit `hypervisorlaunchtype`. Static
  validation still passes with the explicit GHCup toolchain environment: `cabal test all` and
  `cabal build all --ghc-options=-Werror` pass from `core/`, and `cabal test all` / `cabal build all
  --ghc-options=-Werror` pass from `demo/` (demo `14/14` plus embedded core `252/252`).
- 2026-06-28 hypervisor-launch reconciliation: `HostBootstrap.Ensure.Wsl2` now probes firmware
  virtualization separately, checks `HyperVisorPresent`, resolves `Bcdedit` through `HostTool`, runs
  `bcdedit /set hypervisorlaunchtype auto` when the Windows hypervisor is not present, normalizes
  NUL-separated `wsl.exe` diagnostic text, and returns the explicit reboot-required stop after changing
  boot state. Static validation passes: `cabal test all` from `core/` (`All 253 tests passed`),
  `cabal build all --ghc-options=-Werror` from `core/`, `cabal build all --ghc-options=-Werror` from
  `demo/`, and `poetry run python -m hostbootstrap.check_code`. The rebuilt
  `hostbootstrap-demo.exe project up` reached `ensure wsl2`, set the boot entry, and failed closed with
  `ensure wsl2: host reboot required after WSL2 hypervisor launch configuration; reboot and retry`;
  `bcdedit /enum {current}` now reports `hypervisorlaunchtype Auto`.
- 2026-06-28 follow-up validation: the host still has not crossed the reboot boundary
  (`HyperVisorPresent = False` while `VirtualizationFirmwareEnabled = True` and `hypervisorlaunchtype
  Auto` is present). `wsl --status` still reports that WSL2 cannot start, and `wsl --list --verbose`
  still reports no installed distributions. Static gates remain clean: `cabal test all` from `core/`
  (`All 253 tests passed`), `cabal build all --ghc-options=-Werror` from `core/`, `cabal test all` from
  `demo/` (demo `14/14` plus embedded core `253/253`), `cabal build all --ghc-options=-Werror` from
  `demo/`, `poetry run python -m hostbootstrap.check_code`, and `poetry run python -m
  hostbootstrap.test_all` (`175 passed`).
- 2026-06-29 post-reboot validation: WSL2 platform readiness is now present (`HyperVisorPresent = True`,
  `VirtualizationFirmwareEnabled = True`, `wsl --status` succeeds with default WSL version 2). The
  Windows `hostbootstrap-demo.exe project up` path reaches the binary-owned WSL2 provider, registers and
  enters `hostbootstrap-demo-vm`, stages source/config under `/root/hostbootstrap`, installs the local
  Python bootstrapper with `pipx`, builds the in-distro host-native demo binary, installs Docker in the
  distro, and starts the project-container build from
  `docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64`. A live WSL2 run reached a tagged
  `hostbootstrap-demo:local` image and a running kind control-plane, and the in-Dockerfile gate reached
  pinned `fourmolu`, `hlint` (`No hints`), `cabal -Werror`, `spago build`, and `esbuild`; however the
  lifecycle did not close because the WSL/Docker session later exits non-zero before `test run all` and
  `project destroy`. Repeated closure attempts fail during or immediately after the in-distro Docker
  build (`COPY demo` / `RUN cp docker/container.cabal.project cabal.project`) with the parent
  `wsl -d hostbootstrap-demo-vm -- ...` session ending non-zero or with `Wsl/Service/0x80072746`. A clean
  `wsl --shutdown` recovers the distro and `/root` remains writable. A direct `hostbootstrap-demo.exe
  project destroy` against the partial stack succeeds through the guarded WSL2 delete path
  (`project destroy: deleting hostbootstrap-demo-vm`) and preserves `demo/.data`, but that partial
  teardown does not replace the missing successful `project up` -> `test run all` -> `project destroy`
  closure run.
- **2026-07-01 closure run: the full Windows/WSL2 lifecycle closed `6/6`.** With Sprint 9.7's honest cordon
  **applied**, `hostbootstrap-demo` `test run all` wrote the `.wslconfig` `[wsl2]` ceiling and ran
  `wsl --shutdown`, registered/entered `hostbootstrap-demo-vm`, built the in-distro binary (build #2) and
  the project image (build #3) **without the earlier utility-VM session drop**, stood up kind/Harbor/web on
  the VM's Docker, and reported `test report: 6/6 passed` across both message variants (`"Hello, world!"`
  and `"Hello, Universe!"`; `pristine-bootstrap`/`web-build`/`e2e-tabs` × 2), then `project destroy` tore
  down through the guarded `wsl --unregister` path and restored `.wslconfig` with host `.data` preserved.
  The intermittent `Wsl/Service/0x80072746` drop did not recur once the budget wall was applied.

#### Remaining Work

None. The real Windows closure ran to completion on **2026-07-01**: with Sprint 9.7's honest cordon
**applied** (the `.wslconfig` ceiling + `wsl --shutdown` + `swap`, and the stable total-memory preflight),
`project up` registered/entered the managed Ubuntu-24.04 distro **with the ceiling in effect**, brought up
in-distro Docker/kind **without the `Wsl/Service/0x80072746` session drop** (whose root cause — the cordon
computed but never written — Sprint 9.7 fixed), deployed the workload, ran the lifted project-container
assertions reporting **`6/6`**, and `project destroy` tore down through guarded `wsl --unregister`
(restoring `.wslconfig`) with host `.data` preserved. The 10 GiB budget fit on the 16 GB host with the
applied ceiling + swap, so no floor-lowering fallback was needed.

This was Phase 11 work only; it did not block the closed Phase 2 bootstrap, Phase 3 CUDA-on-Windows
reconciler, or Phase 9 Windows capacity/sizing surfaces.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/wsl2.md` - **(new)** the Windows WSL2 host provider: `ensure wsl2`, the
  `wsl --import` / `wsl -d <distro> --` / `wsl --terminate` / `wsl --shutdown` / guarded `wsl --unregister`
  lifecycle, `classifyWsl2Readiness`, and the `wsl2SizingArgs` budget cordon (the `.wslconfig` + vhdx wall),
  with a WRONG/RIGHT pair (WRONG: bare `$PATH` `wsl` / unguarded `wsl --unregister`; RIGHT: resolved
  `AbsExe` / name-prefix-guarded destroy).
- `documents/engineering/incus.md` - the host-provider axis, the `ensure incus` install, the VM lifecycle
  and `incus exec` dispatch, the reboot reconcile, and the `incusSizingArgs` budget cordon, with a
  WRONG/RIGHT pair (WRONG: bare `$PATH` `incus` / unguarded `incus delete`; RIGHT: resolved `AbsExe` /
  name-prefix-guarded destroy).
- `documents/engineering/lima.md` - the Apple Silicon Lima VM provider used by the worked demo,
  cross-referencing the WSL2 Windows peer (`wsl2.md`).

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` - the `HostTarget` parameterization of the run-models,
  including the WSL2-backed `InVM` on Windows.

**Operations docs to create/update:**
- `documents/operations/demo_runbook.md` - the demo's Windows/WSL2 provider path alongside the Lima/Incus
  paths (provider-parameterized; no demo code change).

**Cross-references to add:**
- `documents/engineering/ensure_reconcilers.md` adds the `ensure incus` and `ensure wsl2` rows.
- `system-components.md` adds `HostBootstrap.HostTarget`, `HostBootstrap.Incus`, `HostBootstrap.Ensure.Incus`,
  `HostBootstrap.Wsl2`, `HostBootstrap.Ensure.Wsl2`, the `Wsl` host tool, and the `ensure incus` /
  `ensure wsl2` reconciler rows.
- `development_plan_standards.md` § U records WSL2 as the Windows VM-provider peer of Lima/Incus.
