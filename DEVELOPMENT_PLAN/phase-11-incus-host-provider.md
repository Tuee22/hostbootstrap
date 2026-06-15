# Phase 11: incus First-Class Host-Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)

> **Purpose**: Add `incus` as a first-class host-provider axis (a target linux host is either the local
> host or an incus VM) so anything `hostbootstrap` deploys on an unvirtualized linux host it can deploy
> inside an incus linux VM, with the same machinery and the same budget cordon.

## Phase Status

**Status**: Done

`incus` is the host-provider axis. `HostTool` includes the `Incus` constructor (resolved to an `AbsExe`
like every host tool); `HostBootstrap.Ensure.Incus` is a cross-substrate install-and-verify reconciler
(Colima-backed Incus runtime on Apple, native daemon on Linux); `HostBootstrap.HostTarget`
parameterizes linux-host operations by `HostTarget = Local | InVM IncusVM`; `HostBootstrap.Incus`
carries the VM lifecycle argv and `classifyDockerReadiness`; and `incusSizingArgs` uses the canonical
quantity parser to cordon the VM at the wall
(`limits.cpu`/`limits.memory`/`root,size`). `incus` is not a substrate and not a fifth run-model; it is a
supported host-provider layer.

`HostBootstrap.Lift` is the subcommand-level self-reference lift. It generalizes the two-case
`HostTarget = Local | InVM` tool-level lift to an n-level context stack (`Local`, `InVM`, `InContainer`)
so a binary crosses any boundary by invoking its own subcommand in the nested context. The pure cores,
argv builders, dispatch, and lift fold are unit-tested, and the worked demo exercises the in-VM and
in-container path in real runs. This phase is `Done`.

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
subcommand in the nested context (`incus exec` for a VM, `docker run --rm` for a container whose
`ENTRYPOINT` is the binary).

#### Deliverables

- `HostBootstrap.Lift`: `LiftContext` (a stack of `ViaVM`/`ViaContainer` layers with `inVM`/`inContainer`
  builders), `SelfRef` (binary identity, separate from `HostConfig`), the pure
  `foldLift :: SelfRef -> LiftContext -> [String] -> LiftDispatch`, and the `liftSubcommand` IO seam
  (reusing `runTool`; a new `runSelf` for the binary itself). `HostTarget`/`runInTarget` are kept
  alongside as the narrower tool-level lift.
- The argv fold honors § K (absolute tool only at the outermost host hop; bare `$PATH` names nested) and
  the container `ENTRYPOINT`-is-the-binary contract; a `VM`-then-`Container` stack folds to
  `incus exec <vm> -- docker run --rm <image> <subcmd>`.

#### Validation

- `LiftSpec` asserts the pure fold for `Local`, `InVM`, `InContainer`, and `VM`-then-`Container` nesting,
  plus the container argv builder. `cabal test` passes.

#### Remaining Work

None. The lift primitive and its `LiftSpec` tests are implemented, and the demo composes it.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/incus.md` - the host-provider axis, the `ensure incus` install, the VM lifecycle
  and `incus exec` dispatch, the reboot reconcile, and the `incusSizingArgs` budget cordon, with a
  WRONG/RIGHT pair (WRONG: bare `$PATH` `incus` / unguarded `incus delete`; RIGHT: resolved `AbsExe` /
  name-prefix-guarded destroy).

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` - the `HostTarget` parameterization of the run-models.

**Cross-references to add:**
- `documents/engineering/ensure_reconcilers.md` adds the `ensure incus` row.
- `system-components.md` adds `HostBootstrap.HostTarget`, `HostBootstrap.Incus`, `HostBootstrap.Ensure.Incus`,
  and the `ensure incus` reconciler row.
