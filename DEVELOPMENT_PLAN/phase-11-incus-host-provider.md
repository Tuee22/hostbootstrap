# Phase 11: incus First-Class Host-Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)

> **Purpose**: Add VM providers as first-class host-provider axes so anything `hostbootstrap` deploys on
> an unvirtualized linux host it can deploy inside a managed Linux VM, with the same machinery and the
> same budget cordon. Native Linux uses Incus; Apple Silicon uses a Lima VM for the worked demo; Windows
> uses a WSL2 Ubuntu-24.04 distro.

## Phase Status

**Status**: Active

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
Sprint 11.7 (`[Planned]`), which also carries the Windows/WSL2 demo real-run validation.

## Remaining Work

The **Windows WSL2 host provider** is the open work — Sprint 11.7 (`[Planned]`). Native Linux remains the
Incus provider path and Apple Silicon uses Lima for the worked demo's pristine VM path; WSL2 is the Windows
peer. The pure `HostBootstrap.Wsl2` argv builders, `classifyWsl2Readiness`, `ensure wsl2`, and the WSL2
lift fold are cabal-test-closable; the real Windows/WSL2 demo lifecycle is Sprint 11.7's real-run-gated
remaining work.

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

### Sprint 11.7: Windows WSL2 host provider [Planned]

**Status**: Planned
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
- `classifyWsl2Readiness :: (ExitCode, String, String) -> Ready | NeedsReboot | Unsatisfiable` is the
  host-reboot verdict — the structural peer of the Incus `classifyDockerReadiness` `NeedsReboot`
  (Sprint 11.3); a fresh `wsl --install` requiring a host reboot is classified `NeedsReboot` so the caller
  surfaces the reboot instruction rather than proceeding.

#### Deliverables

- `HostBootstrap.Wsl2`: the pure argv builders `wsl --import <distro> <dir> <tarball>`,
  `wsl -d <distro> -- <inner>`, `wsl --terminate <distro>`, `wsl --shutdown`, and the name-prefix
  delete-guarded `wsl --unregister <distro>` (the guarded destroy, reusing the harness `guardTestDelete`
  idiom), plus `classifyWsl2Readiness`. The distro is sized to the budget wall by `wsl2SizingArgs` (the
  `.wslconfig` `[wsl2]` memory/processors + vhdx cap), the pure builder
  [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md) owns.
- `HostBootstrap.Ensure.Wsl2` exposes `ensure wsl2` as the windows-cpu + windows-gpu install-and-verify
  reconciler, wired into `allReconcilers`; `HostTool` gains the `Wsl` constructor
  (`toolCommandName Wsl = "wsl"`) resolved to an `AbsExe`.
- `HostBootstrap.Lift` folds a provider-backed VM layer through WSL2 into the Ubuntu-24.04 distro
  (`wsl -d <distro> -- <inner>`), so a `VM`-then-`Container` stack on Windows folds to
  `wsl -d <distro> -- docker run --rm <image> <subcmd>` — Docker + kind + the workload run **inside the
  distro**, exactly as Lima/Incus. The in-distro tool is the distro's own `$PATH` binary reached through
  the single host `wsl -d` (§ K governs host invocation only).

#### Validation

- `Wsl2Spec` asserts the pure `wsl --import` / `wsl -d <distro> --` / `wsl --terminate` / `wsl --shutdown`
  argv, the name-prefix-guarded `wsl --unregister` (refusing a non-prefixed distro), and the
  `classifyWsl2Readiness` branches; `EnsureSpec` asserts `wsl2` applicability (windows-cpu + windows-gpu)
  and wrong-host fail-fast; `LiftSpec` covers the WSL2 VM fold; `HostToolSpec` covers the `Wsl` constructor.
  `cabal test all` passes.

#### Remaining Work

Real-Windows/WSL2 validation (real-run-gated, § C): the pure argv builders, `classifyWsl2Readiness`,
`ensure wsl2` applicability, and the WSL2 lift fold are cabal-test-closable; the live closure — the full
Windows demo lifecycle (`ensure wsl2` → `wsl --import` + size the Ubuntu-24.04 distro → in-distro
Docker/kind bring-up → the lifted project-container `test all` reporting `3/3 passed` → guarded
`wsl --unregister`, host `.data` preserved) — is this sprint's remaining work on a real Windows host.

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
