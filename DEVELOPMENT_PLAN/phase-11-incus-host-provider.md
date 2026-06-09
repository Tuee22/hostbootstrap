# Phase 11: incus First-Class Host-Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-10-standardized-test-harness.md](phase-10-standardized-test-harness.md)

> **Purpose**: Add `incus` as a first-class host-provider axis (a target linux host is either the local
> host or an incus VM) so anything `hostbootstrap` deploys on an unvirtualized linux host it can deploy
> inside an incus linux VM, with the same machinery and the same budget cordon.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-3 (the install-and-verify reconciler model), phase-9 (the one canonical parser /
sizing args), phase-10 (the harness and the delete-guard idiom)

`incus` (the LXD successor; installs via Homebrew on apple-silicon and apt on ubuntu-24.04) is added
alongside the other host tools. It is not a substrate (the VM is still `linux-cpu`/`linux-gpu` inside) and
not a fifth run-model; it parameterizes the existing build / ensure-docker / cluster / harbor / run /
harness machinery by a typed `HostTarget`. `incus` is not standardized for all workflows — the demo uses
it to encapsulate a fresh linux host — but it is first-class (see
[development_plan_standards.md § U](development_plan_standards.md)).

## Phase Objective

Land the host-provider axis: the `ensure incus` install-and-verify reconciler, the `HostTarget` dispatch,
the VM lifecycle, the reboot-to-ready reconcile, and the budget-sized VM, such that every linux-host
operation runs against `Local` or `InVM` with no per-call branching.

## Sprints

### Sprint 11.1: `HostTool Incus` and `ensure incus` [Blocked]

**Status**: Blocked
**Blocked by**: phase-3
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/HostTool.hs`, `haskell/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs` (planned)
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

### Sprint 11.2: `HostTarget` and the incus driver [Blocked]

**Status**: Blocked
**Blocked by**: phase-11 (sprint 11.1)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/HostTarget.hs`, `haskell/hostbootstrap-core/src/HostBootstrap/Incus.hs` (planned)
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

### Sprint 11.3: Reboot-to-ready reconcile [Blocked]

**Status**: Blocked
**Blocked by**: phase-11 (sprint 11.2)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Incus.hs` (planned)
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

### Sprint 11.4: `incusSizingArgs` and the in-VM deployment path [Blocked]

**Status**: Blocked
**Blocked by**: phase-9 (sprint 9.1), phase-11 (sprint 11.2)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs` (planned)
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

GPU passthrough (`linux-gpu` inside an incus VM, CUDA/nvkind) is a documented follow-on; apple-silicon
nested-virt is confirmed or deferred per the open item in the unified plan.

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
