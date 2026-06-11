# Phase 11: incus First-Class Host-Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)

> **Purpose**: Add `incus` as a first-class host-provider axis (a target linux host is either the local
> host or an incus VM) so anything `hostbootstrap` deploys on an unvirtualized linux host it can deploy
> inside an incus linux VM, with the same machinery and the same budget cordon.

## Phase Status

**Status**: Done

`incus` is **landed** as the host-provider axis. `HostTool` gained the `Incus` constructor (resolved to
an `AbsExe` like every tool); `HostBootstrap.Ensure.Incus` is the first cross-substrate reconciler
(`appliesTo = isAppleSilicon || isLinux`, install-and-verify via `brew`/`apt` + `incus admin init
--minimal`); `HostBootstrap.HostTarget` parameterizes every linux-host operation by `HostTarget =
Local | InVM IncusVM` (`runInTarget` dispatches one `incus exec`); `HostBootstrap.Incus` carries the VM
lifecycle argv (`launch`/`exec`/`restart`/name-guarded `delete`) and the pure
`classifyDockerReadiness`; and `incusSizingArgs` (one canonical parser) cordons the VM at the wall
(`limits.cpu`/`limits.memory`/`root,size`). It is not a substrate and not a fifth run-model; it is not
standardized for all workflows — the demo uses it to encapsulate a fresh linux host — but it is
first-class (see [development_plan_standards.md § U](development_plan_standards.md)). The pure cores, the
argv builders, and the dispatch are implemented and unit-tested; the live in-VM run is exercised in real
runs (the [demo](phase-13-hostbootstrap-demo.md)), the same standard the cluster lifecycle (Phase 5)
follows, so this phase is closed. GPU passthrough (`linux-gpu` inside an incus VM, CUDA/nvkind) and
apple-silicon nested-virt are documented **future follow-ons**, outside this phase's scope.

**Reopened (Sprint 11.5).** Sprints 11.1–11.4 remain `Done`; the phase is reopened to add the
**self-reference lift** (`HostBootstrap.Lift`), which generalizes the two-case `HostTarget = Local | InVM`
(retained as the tool-level lift) to an n-level context stack (`Local | InVM | InContainer`) so a binary
crosses any boundary by invoking its own subcommand in the nested context (see
[development_plan_standards.md § U](development_plan_standards.md) and
[composition_methodology](../documents/architecture/composition_methodology.md)). Sprints 11.1–11.5 are
closed: the lift primitive and its `LiftSpec` tests are landed and the demo composes it (the `deploy`
chain and the lifted cluster seams); the live in-container run is exercised in the
[demo](phase-13-hostbootstrap-demo.md), the same standard the original phase closed under.

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
- Install-and-verify: `brew install incus` on apple-silicon (precondition `ensure homebrew`);
  `sudo apt-get install -y incus` + `incus admin init --minimal` on ubuntu-24.04. Probe-first/idempotent;
  fail-fast on a genuinely unsupported host.

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

None for this sprint's scope (`incusSizingArgs` + the `InVM`-target deployment path are implemented and
unit-tested; the live in-VM run is exercised in real runs). GPU passthrough (`linux-gpu` inside an incus
VM, CUDA/nvkind) and apple-silicon nested-virt are documented **future follow-ons**, outside this phase.

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

None. The lift primitive and its `LiftSpec` tests are landed and the demo composes it; the live
in-container run is exercised in the [demo](phase-13-hostbootstrap-demo.md), the standard this phase
closes under.

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
