# Phase 11: Incus first-class host-provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)

> **Purpose**: Add VM providers as first-class host-provider axes so anything `hostbootstrap` deploys on
> an unvirtualized linux host it can deploy inside a managed Linux VM, with the same machinery and the
> same budget cordon. Native Linux uses Incus; Apple Silicon uses a Lima VM for the worked demo; Windows
> uses a WSL2 Ubuntu-24.04 distro.

## Phase Status

**Status**: Active
**Blocked by**: None (Sprint 9.10 is complete)

**Updated 2026-07-27 — the ownership invariant was restated and this sprint's target changed shape.**
Sprint 11.10 removed the parallel `HostTarget`/Provider boundary, unused provider
classifiers/builders, demo-local Incus compensation, and direct-host alias bypass; it also added the total
Incus daemon/permission/VM-capability/egress probe. Typed guest-alias operations and a crash-recovery
model/byte transformer for the global WSL wall now exist as static foundations.

§ EE no longer demands an OS-protected namespace plus an identity-bound conditional kernel mutation — a
requirement no substrate met, which is why alias backend discovery returned `Unsupported` on Lima, Incus
**and** WSL2 while production kept an unowned `ln -s`. It now demands the four **Locked-Origin Identity
Ownership** clauses (see
[ownership_invariant](../documents/architecture/ownership_invariant.md)), which every substrate can hold
with dependencies already present. Two consequences for this sprint:

- **The hardened Windows broker service is out of scope.** It was scoped because the native shim could
  not meet the superseded bar. Under the restated invariant the bar is met without a privileged service,
  and the shim itself is superseded by a portable backend — no `.c` is retained in the repository.
- **One backend serves every lane.** All three provider guests run the same Linux image, so `flock`, a
  host-side origin record, and `stat -c '%d %i'` identity binding close the alias on WSL2, Lima, and
  Incus together. Lima and Incus gain clauses 2–4 for the first time; this is a strengthening off
  Windows, not a Windows-only repair.

**Updated 2026-07-28 — the global WSL wall half is closed.** The portable host-wall driver, its POSIX and
`Win32` backends, and the deletion of the C shim landed together with production integration: the
lifecycle's WSL effects are now pathname-free wall acquire/release over a journalled origin record, and
the backup-existence route is removed. The ownership suite is un-gated and runs on every substrate.

Production still uses the historical guest **alias** path (`ln -s` over alias facts, minting no receipt).
That production migration and the native provider gates remain open; the `Win32` backend in particular has
no native run yet. The Windows `8/8` result below is dated evidence for the earlier implementation, not
current closure.

**Reopened 2026-07-21, CLOSED `Done` 2026-07-23 — the guest-side durable alias as pure, readiness-gated
provider data.** The 2026-07-19 host-path share primitive (Sprint 11.8) delivered only the **host-side** half
(`spShare`/`ShareReconcile`). The **guest-side** durable alias that makes the share usable at the Docker
boundary was then added (commit `6f08375`) as a demo-local `set -eu` shell step — ungated, one-shot, and it
**collapsed to a bare `ExitFailure 1`** on the Windows/WSL2 `test run all` gate (0/8). Sprint 11.9 recast it
as a pure `AliasState` primitive gated by a `Ready DurableShareMounted` witness
([development_plan_standards](development_plan_standards.md) § CC/§ DD), folding the three hand-coded copies of
the alias state machine into one classifier; it depends on the legible-failure surface (phase-10 Sprint 10.8)
and the readiness framework (phase-9 Sprint 9.8). **CLOSED** on a live Windows/WSL2 `test run all` reporting
**`8/8 passed`** (2026-07-23): the durable alias now links cleanly —
`vm up: linked durable alias /var/tmp/hostbootstrap-demo-data -> /mnt/c/Users/Matt/hostbootstrap/demo/.data` —
on both variants, the exact step that collapsed `0/8` before. That closure proved only the historical
witness-threaded VM-lane call ordering and live result. Sprint 9.10 has since removed
`HostBootstrap.Readiness.Internal` and replaced the forgeable phantom with opaque
plan/resource-indexed readiness; Sprint 11.10 owns migrating this provider path from non-authorizing
compatibility observations to prepared operations.

**Historical reopening (2026-07-19) — host-path share primitive.** At that point the governed docs asserted
that a project's `.data` survived teardown as *host* state on every provider, but every substrate staged
only host → guest, `SubstrateProvider` carried no share/mount field, and a guest write had no path to the
host. That gap identified this phase's provider-lift slice and became Sprint 11.8; its landed host-side
share and Sprint 11.9's guest alias are described below. The corrected doctrine is
[durable_state](../documents/architecture/durable_state.md).

**Reopened then closed (2026-07-05, cross-substrate reliability hardening).** The demo real-run gate surfaced
provider-lifecycle gaps in this phase's scope: the VM-ready probe (`WaitProbe … true`) only proves the
guest agent answers, not that the network/cloud-init is up, so the first `apt`/`ghcup`/`curl` can race
(Incus/WSL2); the WSL2 `.wslconfig` global cordon is restored **only** on `project destroy` (not on
`down`/re-run/interrupt), so an interrupted run throttles every other distro until a manual restore;
reconcile-to-running skips re-applying the WSL2 cordon; no `vmIdleTimeout` pins the utility VM across
separate `wsl -d` steps; docker-daemon readiness after install is assumed instant; and `wsl --shutdown`
is an unguarded global cross-distro side-effect. The fixes landed (see `## Remaining Work`) and **closed
2026-07-05** by a live Windows/WSL2 `test run all` reporting **`6/6 passed`** — the network gate, the
`vmIdleTimeout=-1` utility-VM pin, and the in-Haskell docker-readiness poll (`pristine-bootstrap: docker
daemon ready in hostbootstrap-demo-vm`, on both bring-ups) all fired, and teardown restored `.wslconfig`.

`incus` is the native Linux host-provider axis. `HostTool` includes the `Incus` constructor (resolved to
an `AbsExe` like every host tool); `HostBootstrap.Ensure.Incus` is a cross-substrate install-and-verify
reconciler (Colima-backed Incus runtime on Apple, native daemon on Linux);
`HostBootstrap.Substrate.Provider` plus `HostBootstrap.Lift` is the production provider route;
`HostBootstrap.Incus` carries the consumed VM lifecycle argv; and
`incusSizingArgs` uses the canonical quantity parser to cordon the VM at the wall
(`limits.cpu`/`limits.memory`/`root,size`). `incus` is not a substrate and not a fifth run-model; it is a
supported host-provider layer. The **Windows** host-provider peer is **WSL2** — an Ubuntu-24.04 distro
reached by `wsl -d <distro> -- …`, the structural peer of the Incus (native Linux) and Lima
(Apple Silicon) VM providers. CPU/memory/swap are one shared WSL utility-VM ceiling and only the
registration-time VHDX cap is per distro; Docker, kind, and the workload run **inside the distro**
exactly as they do inside the Lima/Incus VMs (Sprint 11.7).

`HostBootstrap.Lift` is the production subcommand-level self-reference lift over an n-level context stack
(`Local`, provider-backed `InVM`, `InContainer`), so a binary crosses any boundary by invoking its own
subcommand in the nested context. The former definition-only `HostTarget = Local | InVM` module and
uncalled restart/readiness helpers have been removed. The pure provider
and lift cores, argv builders, dispatch, and fold are unit-tested, and the worked demo exercises the
in-VM and in-container path in real runs.

This phase is reopened because Apple Silicon should not rely on an Incus VM inside the Colima Incus
runtime for the demo VM. The supported Apple path is a Lima VM reached by `limactl shell
hostbootstrap-demo-vm -- ...`, while native Linux keeps the Incus VM path. The pure Lima argv builder,
`ensure lima`, and lift fold are implemented and validated through the full demo lifecycle.

This phase is **reopened** again for the **Windows** host-provider peer. WSL2 is the Windows peer of Lima
(Apple Silicon) and Incus (native Linux): a fresh Ubuntu-24.04 distro reached by `wsl -d <distro> -- …`,
sized at creation by the `wsl2SizingArgs` `.wslconfig` body plus the separate `wsl --install --vhd-size`
argument from
[phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md), running Docker +
kind + the workload inside the distro exactly as the Lima/Incus VMs do. `HostBootstrap.Wsl2` carries the
single consumed install route and other pure argv/output builders,
`HostBootstrap.Ensure.Wsl2` exposes `ensure wsl2` (windows-cpu + windows-gpu), and `HostBootstrap.Lift`
folds a provider-backed VM layer through WSL2 into the distro (`wsl -d <distro> -- <inner>`). That is
Sprint 11.7 (`[Done]`), which also carried the Windows/WSL2 demo real-run validation — **closed 2026-07-01**
by a full `project up` → `test run all` (`6/6`) → `project destroy` Windows lifecycle with the `.wslconfig`
ceiling applied.

## Remaining Work

**Current:** Sprint 11.10 is partially delivered. `SubstrateProvider`/`Lift` is the sole dispatch; dead
provider APIs are removed; Incus has one total capability/egress transition; and the direct-host lane
creates no alias. The typed guest-alias API is in place but its backend discovery returns `Unsupported`
on every substrate, so the production provider path still creates the alias with an unowned `ln -s`. The
WSL foundation models exact present/absent origin, durable unknown phases, apply/restore classification,
and strict UTF-8/UTF-16 config transformation; its byte transformer is portable and is retained
unchanged. The native Windows shim and its FFI are superseded by the portable backend and are tracked for
deletion in the ledger. Production still uses backup-existence inference. The unavailable native Windows
and Linux gates, plus a current disposable Lima lifecycle gate, remain required.

WSL2 also does not release its wall on `project down` while Lima and Incus do; the `spStop` effect list
is this lane's, and the teardown ordering is Sprint 5.7's deliverable with the managed-body change in
Sprint 9.11.

**Historical closure (2026-07-23) — the durable-share primitive.** Sprint 11.8 landed the **host-side** share
(`spShare`/`ShareReconcile`); Sprint 11.9 recast the **guest-side** durable alias as pure, readiness-gated
`AliasState` provider data (replacing the defective demo-local `set -eu` shell step that failed the
Windows/WSL2 gate 0/8 by collapsing to `ExitFailure 1`). Both closed on a live Windows/WSL2 `test run all`
reporting **`8/8 passed`** (2026-07-23): the share mounts (a `Ready DurableShareMounted` probe) and the alias
links cleanly on both variants. The end-to-end durable-root **read-back** contract (write → `project destroy`
→ `project up` → read) is phase-5 Sprint 5.6's; its share/alias mechanism is now validated here. The
historical witness proved threaded call ordering only; Sprint 9.10 has since removed the forge path.
Live provider integration remains Sprint 11.10 work.

**Historical reopening 2026-07-05 — provider lifecycle reliability. Code landed, code-check-validated, and
real-run-closed (§ C) 2026-07-05:**

- **Network/cloud-init-aware VM-ready probe — landed.** `runVmUp` now runs `waitVMNetwork` after the guest
  agent answers: it lets cloud-init finish if present (`timeout 90 cloud-init status --wait`) then requires
  DNS to resolve the apt mirror (`getent hosts archive.ubuntu.com`), bounded-retry, so the first in-VM
  `apt`/`ghcup`/`curl` is not scheduled before an initial configured-network observation
  (Incus/WSL2). It does not guarantee the external network remains available after that observation.
- **`.wslconfig` restore for an existing original — landed; absent-original crash recovery remains
  open.** The WSL2 `spStop` emits `RestoreHostFile`, so `project down` restores the global cordon when an
  original file produced a backup. `mergeWslConfigWithBackup` preserves that backup across retry. If the
  original was absent and the first run crashes after writing, no absence marker exists; retry can back
  up generated content as the “original.” Sprint 11.10's receipt target owns that remaining state.
- **Config re-merge + idle-timeout on reconcile — landed; effective-wall reconciliation remains open.**
  On the exists path `runVmUp` re-applies the launch's **file** effects (`fileEffectsOnly` → the
  `.wslconfig` merge, never the one-time install), and
  `wsl2SizingArgs` now emits `vmIdleTimeout=-1` so the utility VM survives the gaps between separate `wsl -d`
  steps (`HostBootstrap.Cluster.Cordon`; `CordonSpec`/`ProviderSpec` updated). Shutdown runs only for a
  stopped distro; a running distro can retain its old live CPU/memory ceiling, so this is not a general
  applied re-cordon. Sprint 9.10/11.10 own observation and `Unchanged | Migrated | Refused`.
- **Docker-daemon readiness poll — landed.** The in-VM Docker install step polls `docker info` to Ready
  (bounded 30×2 s) after `systemctl enable --now docker` + the socket ACL, instead of assuming the
  socket/ACL is instant.
- **Guard/disclose the global `wsl --shutdown` — landed.** `runVmUp` discloses the cross-distro side-effect
  (`discloseWslShutdown`) before applying the WSL2 launch (the historical `0x80072746` session-drop surface).

- **Docker-readiness poll moved to Haskell (real-run correction) — landed.** The docker-readiness poll first
  landed as an inline shell `for` loop; the real run hit `bash: -c: line 2: syntax error near unexpected
  token '2'` because a loop with a single-quoted `echo` mangles through the Windows PowerShell→`wsl`→`bash`
  quoting path (the `'`→`''` escaping splits the line). Fixed by moving the retry into Haskell
  (`waitDockerReady`, a simple `docker info >/dev/null 2>&1` probe — the same shape `waitVMNetwork`/
  `substrateWait` use safely).

Code-check gate (2026-07-05): `cabal build all --ghc-options=-Werror` + `cabal test all` (292) green from
`core/`; the demo `-Werror` build + demo/embedded-core suites green from `demo/`. **Closed (real-run, § C,
2026-07-05):** the network gate, the existing-original `.wslconfig` restore, the reconcile file re-merge,
the
Haskell docker-readiness poll, and the `wsl --shutdown` disclosure were exercised by the live Windows/WSL2
`test run all` **`6/6`** run. This evidence did not prove absent-original crash recovery or a changed
wall on an already-running utility VM; those remain in Sprint 11.10.

The **Windows WSL2 host provider** is implemented, unit-validated, and now **real-run-closed
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
through the guarded `wsl --unregister` path, restoring `.wslconfig`. Native
Linux remains the Incus provider path and Apple Silicon uses Lima; WSL2 is the validated Windows peer.

Static validation is clean: `cabal test all` and `cabal build all --ghc-options=-Werror` from `core/`,
`cabal test all` from `demo/` (demo suite plus the embedded core suite), `cabal build all
--ghc-options=-Werror` from `demo/`, and `poetry run python -m hostbootstrap.check_code`.

## Phase Objective

Land one host-provider axis: the install-and-verify reconcilers, provider-owned VM lifecycle and
readiness transitions, creation-time Lima/Incus walls plus WSL's shared utility-VM ceiling and
registration-time VHDX cap, and the `SubstrateProvider`/`Lift` dispatch through which local, VM, and
container frames run without per-call substrate branching. Retire the older definition-only
`HostTarget` route.

## Sprints

### Sprint 11.1: `HostTool Incus` and `ensure incus` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/ensure_reconcilers.md`, `system-components.md`

#### Objective

Add the `HostTool Incus` constructor and the `ensure incus` install-and-verify reconciler, wired into
the reconciler list so the host `incus` resolves to an `AbsExe` across apple-silicon and linux.

#### Reconciler Contract

- `ensure incus` `appliesTo = isAppleSilicon || isLinux`. It is not the first/only cross-substrate
  predicate: `Ensure.Docker` already declares `appliesTo = const True`, while delegating/refusing its
  absent-daemon install path off Linux.
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

**Historical Sprint 11.2 landing (superseded as a dispatch model by `SubstrateProvider`/`Lift`):** land
the original typed `HostTarget` abstraction and the Incus VM lifecycle.

#### Deliverables

- The historical `data HostTarget = Local | InVM IncusVM`; `runInTarget cfg Local t args = runTool cfg t
  args`; `runInTarget cfg (InVM vm) t args = execVM …` (`incus exec <name> -- <cmd>`). At this delivery
  point the module remained as pending cleanup; Sprint 11.10 later deleted it.
- VM lifecycle through the resolved host `incus`: `createVM`, `start`/`stop`, `execVM`, `pushFiles`
  (`incus file push`), `rebootVM`, `destroyVM` (name-prefix delete-guarded through the same historical
  guard idiom; Sprint 10.10 later removed the unconsumed public harness helper). The in-VM tool is the VM's own PATH binary reached through the single host
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

**Historical scope.** This is the original `HostTarget` callback-loop delivery record, not the current
provider contract. Sprint 11.10 later deleted both the definition-only loop and its unconsumed
classifier/restart builder after `SubstrateProvider`/`Lift` became the sole route. See the
[deletion ledger](legacy-tracking-for-deletion.md).

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

**Historical scope.** The `incusSizingArgs` builder is retained. The `HostTarget InVM` path and Harbor
wording below record the original delivery and are not current architecture; Sprint 11.10 owns the one
`SubstrateProvider`/`Lift` path, and the current demo uses registry/MinIO. See the
[deletion ledger](legacy-tracking-for-deletion.md).

#### Objective

Cordon the VM to the budget and run the full deployment surface inside it.

#### Deliverables

- `incusSizingArgs :: Resources -> Either String [String]` (from the one canonical parser) sizing the VM
  (`limits.cpu`, `limits.memory`, `root,size` — incus cordons storage at the VM wall, unlike
  `docker update`). The build / ensure-docker / kind / harbor / run / harness machinery runs against an
  `InVM` target unchanged.

#### Validation

- `CordonSpec` asserts `incusSizingArgs` emits the expected CPU and ceiling-rounded GiB memory/storage
  launch arguments. Accepted quantities need not survive byte-for-byte because provider builders round
  effective byte counts up to whole GiB.

#### Remaining Work

None for the historical creation-argument landing. `incusSizingArgs` and the `InVM` target path are
implemented and unit-tested; existing Incus limits are not observed or reconciled and remain Sprint
9.10 work. GPU passthrough
(`linux-gpu` inside an incus VM, CUDA/nvkind) and apple-silicon nested virtualization are outside this
phase.

### Sprint 11.5: The self-reference lift (`HostBootstrap.Lift`) [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/test/LiftSpec.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/incus.md`, `system-components.md`

#### Objective

**Historical Sprint 11.5 transition:** generalize from the then-current two-case `HostTarget` to the
n-level subcommand-level **self-reference lift**: a binary crosses a context boundary by re-invoking its
own subcommand in the nested context (selected VM provider for a VM, `docker run --rm` for a container
whose `ENTRYPOINT` is the binary). `Lift` is now the production route; retaining the older route is not
part of the current doctrine.

#### Deliverables

- `HostBootstrap.Lift`: `LiftContext` (a stack of `ViaVM`/`ViaContainer` layers with `inVM`/`inContainer`
  builders), `SelfRef` (binary identity, separate from `HostConfig`), the pure
  `foldLift :: SelfRef -> LiftContext -> [String] -> LiftDispatch`, and the `liftSubcommand` IO seam
  (reusing `runTool`; a new `runSelf` for the binary itself). The original landing kept
  `HostTarget`/`runInTarget` alongside temporarily; Sprint 11.10 owns their removal now that they have no
  production consumer.
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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Lima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/operations/demo_runbook.md`, `system-components.md`

#### Objective

This sprint records the historical provider landing. Its former standalone command spellings are
removed; Lima now appears only as the provider-backed step/lift path under the fixed lifecycle surface.

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

- `HostBootstrap.Wsl2`: pure argv builders for the currently consumed
  `wsl --install -d Ubuntu-24.04 --name <distro> --no-launch --vhd-size <size>` route and the separately
  exported/tested `wsl --import <distro> <dir> <tarball>` alternative, plus
  `wsl -d <distro> -- <inner>`, `wsl --terminate <distro>`, `wsl --shutdown`, the name-prefix
  delete-guarded `wsl --unregister <distro>` (the guarded destroy uses the same historical prefix-check
  idiom; Sprint 10.10 later removed the unconsumed public harness helper), and
  `classifyWsl2Readiness`. The import builder had no production consumer, so this historical
  sprint did not make `--import` the selected provisioning route: Sprint 11.10 later deleted it and
  retained `wslInstallArgs` as the one production builder. Phase 9's current `wsl2SizingArgs` owns only the
  **global** `.wslconfig` `[wsl2]` `processors`/`memory`/`swap` utility-VM ceiling (WSL2 has no per-distro
  `wsl --memory`/`--cpu`); the selected install builder separately supplies the per-distro
  registration-time VHDX storage cap.
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
  `hostbootstrap-demo-vm`) and currently provisions it with `wslInstallArgs` if absent,
  the metal frame's declared descent hands off through `inWsl2VM`, source/config staging uses the
  distro's
  `/mnt/<drive>/...` view of host files, and `project destroy` uses the name-prefix-guarded
  `wsl --unregister` builder. Sprint 11.10 later retained install and deleted import.
- **Registry credential forwarding on Windows (operator prerequisite, no new code).** Symmetric with the
  other substrates: with the **standalone Docker CLI** (`docker.exe`, no Docker Desktop) and `docker login`
  (a Docker Hub PAT, no credential helper), the inline token in `%USERPROFILE%\.docker\config.json` is
  discovered by `discoverHostRegistryAuth` and forwarded over the existing WSL2 stdin tunnel into build
  #3's base pull — removing the anonymous rate-limit risk during the Windows lifecycle closure. This
  reuses the existing forwarding rails unchanged; see
  [registry_credentials.md](../documents/engineering/registry_credentials.md) and the
  [demo runbook](../documents/operations/demo_runbook.md) Windows/WSL2 note.

#### Validation

- Historical `Wsl2Spec` asserted both the consumed `wsl --install` builder and the definition-only `wsl --import`
  builder, plus `wsl -d <distro> --` / `wsl --terminate` / `wsl --shutdown` argv, the
  name-prefix-guarded `wsl --unregister` (refusing a non-prefixed distro), and the
  `classifyWsl2Readiness` branches. Testing the import argv was not evidence that production selected it;
  Sprint 11.10 later removed both unconsumed surfaces. `EnsureSpec` asserts `wsl2` applicability (windows-cpu + windows-gpu)
  and wrong-host fail-fast; `LiftSpec` covers the WSL2 VM fold; `HostToolSpec` covers the `Wsl`
  constructor. `cabal test all` passes.
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
  build (`COPY demo` / ordinary `demo/cabal.project`) with the parent
  `wsl -d hostbootstrap-demo-vm -- ...` session ending non-zero or with `Wsl/Service/0x80072746`. A clean
  `wsl --shutdown` recovers the distro and `/root` remains writable. A direct `hostbootstrap-demo.exe
  project destroy` against the partial stack succeeds through the guarded WSL2 delete path
  (`project destroy: deleting hostbootstrap-demo-vm`), but that partial
  teardown does not replace the missing successful `project up` -> `test run all` -> `project destroy`
  closure run.
- **2026-07-01 closure run: the full Windows/WSL2 lifecycle closed `6/6`.** With Sprint 9.7's honest cordon
  **applied**, `hostbootstrap-demo` `test run all` wrote the `.wslconfig` `[wsl2]` ceiling and ran
  `wsl --shutdown`, registered/entered `hostbootstrap-demo-vm`, built the in-distro binary (build #2) and
  the project image (build #3) **without the earlier utility-VM session drop**, stood up kind/Harbor/web on
  the VM's Docker, and reported `test report: 6/6 passed` across both message variants (`"Hello, world!"`
  and `"Hello, Universe!"`; `pristine-bootstrap`/`web-build`/`e2e-tabs` × 2), then `project destroy` tore
  down through the guarded `wsl --unregister` path and restored `.wslconfig`.
  The intermittent `Wsl/Service/0x80072746` drop did not recur once the budget wall was applied.

#### Remaining Work

None. The real Windows closure ran to completion on **2026-07-01**: with Sprint 9.7's honest cordon
**applied** (the `.wslconfig` ceiling + `wsl --shutdown` + `swap`, and the stable total-memory preflight),
`project up` registered/entered the managed Ubuntu-24.04 distro **with the ceiling in effect**, brought up
in-distro Docker/kind **without the `Wsl/Service/0x80072746` session drop** (whose root cause — the cordon
computed but never written — Sprint 9.7 fixed), deployed the workload, ran the lifted project-container
assertions reporting **`6/6`**, and `project destroy` tore down through guarded `wsl --unregister`
(restoring `.wslconfig`). The 10 GiB budget fit on the 16 GB host with the
applied ceiling + swap, so no floor-lowering fallback was needed.

This was Phase 11 work only; it did not block the closed Phase 2 bootstrap, Phase 3 CUDA-on-Windows
reconciler, or Phase 9 Windows capacity/sizing surfaces.

### Sprint 11.8: Per-substrate host-path share primitive [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`, `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`, `core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`
**Docs to update**: `documents/architecture/durable_state.md`, `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/engineering/wsl2.md`

#### Objective

Give the provider lift a way to attach a host directory to its guest, so a durable root can be
host-backed rather than frame-local.

#### Deliverables

- A share field on `SubstrateProvider`, shaped like the existing optional `spReconcileCordon` — the
  three substrates differ in **when** a share may be declared, and the `Maybe` shape already encodes
  "one substrate needs an extra step, the others do not":
  - **Lima** — create-time only; `startVMArgs` builds the whole `limactl start` argv, so the mount is
    an argument of instance creation.
  - **Incus** — post-create; a disk device attached with `incus config device add <vm> <name> disk
    source=… path=…`.
  - **WSL2** — no effect required; drvfs already exposes host drives and `windowsPathToWslMount`
    already performs the path rewrite. The share is a path resolution, not a command.
- Pure argv builders for the Lima mount argument and the Incus disk device, unit-tested in the same
  shape as the existing lifecycle builders.
- The asymmetry documented honestly rather than implied to be uniform — a create-time-only share means
  a running instance cannot gain one without recreation.

#### Validation

- `cabal test` from `core/` — argv shape for each builder, and provider-effect assertions in
  `ProviderSpec` alongside the existing launch/stop/destroy cases.
- Real-run gate (§ C), jointly with phase-5 Sprint 5.6: write state, `project destroy`, `project up`,
  read it back.

#### Remaining Work

**Historical/superseded at Sprint 11.8 closure.** The host-side share (`spShare` / `HostPathShare` /
`ShareReconcile` — the Lima create-time mount, Incus disk device, and WSL2 drvfs path rewrite) landed and
remains this Done sprint's scope. The then-defective guest alias described by the original Remaining Work
was subsequently replaced and live-validated by Sprint 11.9; it is not open 11.8 work. The only
share-related durability proof still open is Phase 5 Sprint 5.6's write → `project destroy` → `project up`
→ read-back gate. None remains in Sprint 11.8.

### Sprint 11.9: VM guest-side durable alias as initial provider data [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`, `demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`
**Docs to update**: `documents/architecture/readiness.md`, `documents/architecture/durable_state.md`, `documents/engineering/wsl2.md`, `documents/engineering/incus.md`, `documents/engineering/lima.md`

#### Objective

Recast the VM guest-side durable alias — the stable Docker-visible symlink to the host-backed share — as
provider data gated by the initial readiness witness, replacing the defective demo-local `set -eu` shell
step that raced and collapsed on the Windows/WSL2 gate. Direct-host totality and consolidation are Sprint
11.10.

#### Deliverables

- A pure `AliasState = AliasAbsent | AliasLinkedCorrectly | AliasLinkedElsewhere FilePath | AliasOccupied`
  with a total `classifyAlias` and a create/remove planner in `HostBootstrap.Substrate.Provider` — the
  guest-side peer of `shareReconcileEffects` (development_plan_standards § DD).
- The VM-shell lane reads alias facts with trivial guest probes (`test -L`, `readlink`, `test -e`) and
  executes the initial shared plan. The direct Linux-GPU `System.Directory` gather/ownership path is not
  closure evidence for this sprint and is explicitly reopened in Sprint 11.10.
- Mount-readiness: a retrying `Probe` proves the guest share is a writable directory and mints a
  `Ready DurableShareMounted` witness (§ CC); `waitVMNetwork` mints a `Ready NetworkReady` the mount probe
  consumes; `mintDurableAlias` requires the mount witness. Those signatures thread
  `substrateWait → waitVMNetwork → awaitDurableShareMounted → mintDurableAlias` in call order, so callers
  using the intended results could not omit a predecessor. At this historical landing the public
  `HostBootstrap.Readiness.Internal.MkReady` still allowed forging; Sprint 9.10 subsequently removed it
  and delivered the sealed, generative, resource-indexed witness.
- A collision (`AliasLinkedElsewhere` / `AliasOccupied`) is a `Failed` message, never a bare exit code.

#### Validation

- `cabal test` from `core/` — `ProviderSpec` (or a new alias spec) covers all four `AliasState` cases, the
  create/remove planner, and the mount/alias probe classification; type checking proves the named
  functions require the preceding result to be threaded. Constructor opacity and resource identity were
  explicitly not validation from this sprint; Sprint 9.10 now supplies them.
- Real-run gate (§ C), jointly with phase-5 Sprint 5.6 and phase-10 Sprint 10.8: the Windows/WSL2
  `test run all` reaches `8/8`, or fails with a legible `LifecycleFailure` naming the cause — never a bare
  `ExitFailure 1`.

#### Remaining Work

**Code landed and static-validated (2026-07-22).** `HostBootstrap.Substrate.Provider` gains a pure
`AliasState` (`AliasAbsent` / `AliasLinkedCorrectly` / `AliasLinkedElsewhere` / `AliasOccupied`) with the
total `classifyAlias` over `AliasFacts` plus the `planAliasEnsure` / `planAliasRemove` planners — a collision
is a legible `Left`, never a bare exit code. The VM-shell lane reads facts with trivial guest probes
(`test -L` / `readlink` / `test -e`) and executes the initial plan. The attempted direct Linux-GPU
`System.Directory` gather/ownership path is not total or exclusive and is reopened in Sprint 11.10 rather
than claimed as this sprint's closure. VM readiness ordering is threaded through the initial witness:
`waitVMNetwork` mints `Ready NetworkReady`, `awaitDurableShareMounted` consumes it and mints
`Ready DurableShareMounted` (a retrying `test -d && test -w` probe), and `mintDurableAlias` requires the mount
witness. This made the intended call graph explicit, but at the time a consumer could forge either
phantom witness. Sprint 9.10 subsequently sealed and resource-indexed readiness. A residual failure is
legible via phase-10 Sprint 10.8's
`LifecycleFailure`. Static gate green:
`cabal test all --ghc-options=-Werror` **core 382** (7 new `ProviderSpec` alias cases) **+ demo 98**.
**Historical VM-lane gate (§ C, 2026-07-23):** the live Windows/WSL2 `test run all` reported **`8/8 passed`** with
the alias linking cleanly on both variants
(`vm up: linked durable alias /var/tmp/hostbootstrap-demo-data -> /mnt/c/…/demo/.data`) — the exact step that
failed `0/8` before. None remains in this narrowed VM-lane scope; Sprint 11.10 owns direct-host totality,
one Provider/Lift path, and exclusive alias ownership; Phase 9 Sprint 9.10 now supplies generative
readiness.

### Sprint 11.10: One provider/lift path and guest durable projections [Active]

**Status**: Active
**Blocked by**: None (Sprint 9.10 is complete)
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/ConfigBytes.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Posix.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Windows.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/composition_methodology.md`,
`documents/engineering/wsl2.md`, `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/incus.md`, `documents/engineering/lima.md`,
`documents/architecture/durable_state.md`, `legacy-tracking-for-deletion.md`

#### Objective

Remove parallel/definition-only provider abstractions, replace provider presence checks with the
capability/egress observations their dependent steps require, and make provider guest aliases one typed
projection primitive without treating them as direct-host path authority.

#### Deliverables

- Retire public `HostTarget` dispatch when no production call consumes it; `SubstrateProvider` plus
  `Lift` becomes the single VM/provider route.
- Remove or integrate the definition-only `wslImportArgs`; WSL provisioning has one command builder used
  by production and tests, including the chosen import/install mechanism and VHDX sizing. Until this
  sprint chooses and validates that route, the plan does not preselect `wsl --import`.
- Replace Linux `ensure incus` client-presence satisfaction with a total daemon-reachability/VM-capability
  probe, and make each provider transition observe required egress before minting readiness for an
  image-pull or guest-bootstrap step. Package presence alone cannot produce `Ready Provider`; delete the
  demo-local `ensureIncusProvider` compensation once core owns that transition.
- Route every VM/provider-guest durable alias through the same `AliasState` classifier,
  receipt-preserving `ReconcileResult` (`ManagedResult` with a `Managed` handle/receipt and
  `Changed Created|Repaired|Adopted` or `Unchanged`, versus `ForeignResult` with only an `Unmanaged`
  handle), exact mounted-share readiness witness, and a protected namespace plus identity-bound
  conditional filesystem operation. The direct-host lane instead consumes Sprint 5.6.1's canonical
  absolute host path and creates no compatibility alias. Same-filesystem placement or exclusive create/rename alone is not
  authoritative against same-privilege replacement; unsupported backends mint no receipt. There is no
  demo-local alias bypass, and no guest alias can enter the host-bind adapter.
- Model WSL global `.wslconfig` mutation and restoration through a platform-authoritative lock/CAS and
  receipt that distinguishes original-present bytes from original-absent before the first write. Retry
  consumes that durable origin rather than inferring ownership from `.bak` existence; teardown restores
  the exact bytes or absence. Return structured conflict when another run/operator owns the setting and
  `Unsupported` rather than calling a process-local sidecar exclusive.

#### Validation

- Source/use tests prove there is one production provider dispatch and every exported argv builder has a
  production consumer.
- Provider probe tables cover missing client, client-present/daemon-absent, permission denied,
  daemon-unreachable, VM-incapable, no-egress, and ready; only the last branch mints the capability
  consumed by the dependent step.
- Alias state-machine tests cover absent, correct, elsewhere, occupied, foreign-owned, and retry states
  for each provider guest path; direct-host tests prove the canonical host path bypasses alias mutation.
- Live WSL2, Lima, Incus, and direct-Linux gates prove provision/reconcile/restore behavior without
  claiming one provider validates another.

#### Remaining Work

**Delivered and statically validated 2026-07-26:**

- deleted public `HostBootstrap.HostTarget`, its result-free reboot loop, the unconsumed Incus/WSL
  readiness classifiers, the unused Incus restart builder, and `wslImportArgs`; every remaining exported
  provider argv builder has a production consumer and `wslInstallArgs` is the one registration route;
- made `vmShellArgs` use the same `Lift.foldLeaf` dispatcher as all other VM handoffs;
- replaced Linux Incus client presence with the total `IncusProviderStatus` table. Linux convergence now
  covers daemon initialization/restart, immediate permission, KVM/QEMU/OVMF, Incus bridge forwarding, and
  `images:` egress; only `IncusProviderReady` enters the opaque capability continuation. Deleted the
  demo-local remediation branch;
- removed the direct-host alias observation/mutation surface; the direct lane consumes the canonical
  same-root host path.

**Static foundations delivered 2026-07-27:**

- added the opaque `DurableAliasResource` path, prepared alias call/release values, typed observations,
  receipt-preserving outcomes, and a definition-only backend capability. The ordinary guest symlink path
  cannot construct it and therefore mints no ownership receipt;
- added a pure WSL global-wall state machine for exact present/absent origin, durable outcome-unknown
  transitions, identity-bound stage/apply/restore classification, opaque receipt/authority values, and
  conservative conflict handling;
- added a bounded, exact byte transformer for UTF-8, UTF-16LE, and UTF-16BE `.wslconfig` files. It
  preserves unrelated bytes and newline/encoding shape, recognizes controlled ASCII keys through the
  first `=`, and refuses malformed or ambiguous bracket-prefixed section syntax. This is portable and is
  **retained unchanged** by the work below;
- added a Windows-only interpreter and narrow C shim exercising the Win32 primitives directly.
  **Superseded 2026-07-27:** the shim was written against the platform-primitive rule, and the restated
  invariant is satisfiable through `Win32`'s existing bindings, so the shim and its FFI are tracked for
  deletion in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). Its crash model
  survives in the pure state machine above.

**Delivered 2026-07-27 (guest-alias ownership backend + WSL2 wall release):**

- the provider-guest durable alias now has a real backend
  (`HostBootstrap.Substrate.Provider.Alias`). `discoverStrongAliasBackend` probes the guest for the POSIX
  ownership tools (`flock`/`stat`/`ln`/`readlink`/`unlink`/`sed`) and mints an opaque `StrongAliasBackend`
  carrying an injectable `GuestExec`; production dispatches it through the provider lift, and a test
  injects a local runner so the four § EE clauses run against a real POSIX filesystem on every substrate
  this suite runs on. `runPreparedGuestAliasCall`/`runPreparedGuestAliasRelease` hold clause 1 (a
  `flock -x` across the observe/mutate/settle bracket), clause 2 (a guest-side origin record written
  before the first mutation), clause 3 (a `device:inode` identity — `stat` lstats the symlink — with a
  `readlink` target guard), and clause 4 (a conditional `unlink` re-observed under the same lock that
  refuses a foreign-replaced link as a structured `Conflict` and leaves it intact). The echoed generation
  is the plan nonce `completeReconcile` must confirm; the kernel identity lives in the origin record.
  Cross-run stable-generation idempotence via journal rehydration remains Sprint 16.6 work;
- `spStop` releases the WSL2 wall on `project down`: it now restores `.wslconfig` **first**, then runs
  `wsl --shutdown` (not `wsl --terminate <distro>`), so the shared utility VM re-reads the uncordoned file
  and drops the memory balloon, against Sprint 9.11's finite idle timeouts. Lima/Incus already release on
  stop. (This is the § EE/Sprint 5.7 uniform-`down` obligation, satisfied at the pure `spStop` layer.)

**Delivered 2026-07-28 (portable host wall, C-shim retirement, `.bak` retirement):**

- the WSL2 global `.wslconfig` **host** wall is now a portable driver over an injected backend.
  `HostBootstrap.Wsl2.GlobalWall.Host` owns the complete recovery driver, the durable record codec, and
  the `HostWallBackend` seam; `HostBootstrap.Wsl2.GlobalWall.Posix` is an `fcntl`/journal-file/
  `device:inode` backend; `HostBootstrap.Wsl2.GlobalWall.Windows` is the production backend over
  `Win32`'s `LockFileEx`, `getFileInformationByHandle`, `MoveFileEx`, and `CreateHardLinkW`. Because a
  byte-range lock is not affine to the acquiring OS thread, `cbits/wsl_global_wall.c`, the
  `if os(windows)` `c-sources`/`extra-libraries` block, the seven `hb_wsl_*` foreign imports, and the
  test-suite `-threaded` carve-out are all deleted. No `.c` remains in the repository;
- the wall spec is **un-gated**. `test/WslGlobalWallWindowsSpec.hs` (Windows-only, `5/5` native subset)
  is replaced by `test/WslGlobalWallHostSpec.hs`, which runs the production driver against a real kernel
  on every substrate the suite runs on: publication and restored absence, exact origin retention and
  byte-identical republication, recovery-name and journal cleanliness, idempotent re-apply, strictly
  monotonic fences, clause-1 serialisation of concurrent entries, symlink refusal, foreign-owner and
  incompatible-spec conflicts, clause-4 refusal to delete a replaced managed target, interrupted-publish
  and interrupted-restore resume, durable armed-leftover reclamation, and the record codec;
- the backup-existence (`.bak`) route is gone. `HostEffect` now carries pathname-free
  `ApplyGlobalWslWall`/`ReleaseGlobalWslWall`; `spStop`/`spDestroy` take the same `ResourceEnvelope` as
  `spLaunch`, so teardown releases exactly the wall bring-up applied; `VMHandles.vmhWslConfigPath`,
  `WriteHostFile`/`MergeWslConfig`/`RestoreHostFile`, `HostBootstrap.Wsl2.mergeWslConfig`, and the demo's
  `writeHostFileWithBackup`/`mergeWslConfigWithBackup`/`backupHostFileOnce`/`restoreHostFile` are
  removed, and the harness teardown assertion now proves the wall **journal** is cleared rather than that
  a backup file is absent.

**Delivered 2026-07-29 (`virtiofsd`: the provider-usability gap this phase's own convergence list
missed).**

The first native Linux CPU lane run on a genuinely pristine Ubuntu 24.04 host reported
`ensure incus: daemon, VM capability, and image-source egress ready` and then failed every case with:

```text
incus config device add hostbootstrap-demo-vm durable-data disk source=… path=… failed (exit 1)
Error: Failed to start device "durable-data": Virtiofsd isn't running
```

`virtiofsd` is what Incus uses to share a host directory into a **VM**, so it is precisely the § DD Incus
`ShareReconcile` — a disk device attached post-create — and the demo's durable root depends on it. It is
not pulled in by `incus` or by `qemu-system-x86`, and this phase's convergence list checked
KVM/QEMU/OVMF but not `virtiofsd`. That made `IncusProviderReady` a claim about installed binaries rather
than a usable provider, which is the exact distinction § L draws.

It was invisible until now for a specific reason worth recording: a share attached to a **stopped**
instance before `incus start` succeeds without `virtiofsd`, and both the 2026-07-29 Sprint 5.7 storage-wall
run and ordinary manual use take that cold-plug path. Only the demo's post-create hot-plug needs the
daemon, so no earlier run could have surfaced it.

- `reconcileLinuxIncus` now installs `virtiofsd` alongside `qemu-system-x86`, `ovmf`, and `acl`.
- The VM-capability probe is the pure `linuxVmCapabilityProbeScript`: QEMU, an OVMF firmware image, **and**
  a `virtiofsd` Incus can exec, joined with `&&` so a missing conjunct yields `IncusVMIncapable` rather
  than a ready row. `virtiofsdCandidatePaths` pins Incus's own search order
  (`/usr/libexec/virtiofsd`, `/usr/lib/qemu/virtiofsd`, `/usr/lib/virtiofsd`) with a `PATH` fallback, so the
  list lives in one tested value instead of a call-site string.
- `EnsureSpec` pins the candidate order, asserts each conjunct is present, and asserts the conjunct count,
  so dropping one is a test failure rather than a silently weaker probe.

Core gate: **738/738** under `-Werror`.

**Delivered 2026-07-29 (the share ATTACH was itself ungated — the § CC violation one step earlier in the
chain).**

With `virtiofsd` installed, the same native lane still collapsed to `0/10`, now with:

```text
vm up: durable share not mounted/writable in hostbootstrap-demo-vm:
  did not become ready within the poll budget (command has not succeeded)
```

The device attach reported success and the guest never mounted it. Reproduced directly and minimally on
the same host, which makes the rule exact:

- attach the disk device **after** the guest agent answers → `incus_durable-data … type virtiofs (rw)`
  appears and is writable;
- attach it **immediately after launch**, before the agent answers → `Device durable-data added` still
  succeeds, and the guest **never** mounts it. No later probe can recover, because nothing re-triggers the
  mount.

On a provider whose share is a post-create device (§ DD), it is the **guest agent** that performs the
mount, so the attach is a frame mutation with a real dependency. `runVmUp` ran it before `substrateWait`
with no witness at all — while the mount probe and the alias step immediately after it were both
readiness-gated, and a comment asserted the ordering was type-enforced. It was enforced for the two steps
that consume the share and not for the one that creates it.

This is the same class as the defect Sprint 11.9 already recorded ("the ungated `set -eu` step that
collapsed `0/8` is gone"), one step earlier, and it collapsed `0/10` the same way. It could not have been
caught before: WSL2 has no attach step at all (`hpsReconcile = Nothing`, because drvfs already exposes the
drive), so the `6/6` and `8/8` runs never executed this path, and the 2026-06-18 Incus run predates the
current alias/readiness recast.

`reconcileDurableShare` now takes `ObservedReady VMReady` and runs after `substrateWait`, whose probe
(`incus exec <vm> -- true`) is exactly the agent probe it depends on. Because the witness is a parameter,
calling it before the wait is a **compile error**, which is the guarantee the old comment only claimed.

Gates: demo **106** and core **738** under `-Werror`; demo `fourmolu --mode check app src` clean.

**Still open:**

- wire the guest-alias backend into production: migrate the demo's `mintDurableAlias` `ln -s` to the
  plan-owned prepared operation over the backend (building the production `GuestExec` from the provider
  lift), and remove the alias-fact bypass — coordinated with the plan-driven wiring shared with Sprints
  5.7 and 16.6;
- run current native WSL2 and disposable Lima gates, and the native Incus/direct-Linux gate. The Windows
  `8/8` snapshot validates the historical WSL lane only and a macOS run cannot close a Linux or Windows
  lane. The `Win32` backend specifically has **no** native run yet: its clause realization is validated
  only by its POSIX peer through the shared driver.

**Validation evidence (2026-07-26):** `cabal build all --ghc-options=-Werror` and the complete **448**
core tests passed; the demo `-Werror` build plus **105** demo and embedded **448** core tests passed; the
provider source/use drift test passed through the supported Python runner; and the focused documentation
validator passed. A disposable Apple `hostbootstrap-phase-11-10-smoke` Lima instance proved exact
2-CPU/4-GiB/20-GiB VZ sizing, its sole writable host share, guest DNS egress, already-running no-op,
stop/start recovery, and guarded exact deletion; no pre-existing Lima instance existed, and the
disposable instance and mount directory were removed. This closes only the available Lima lifecycle
slice, not the guest-alias ownership primitive or any Windows/native-Linux gate.

**Focused validation evidence (2026-07-27):** the alias suite passed **9**, the affected Reconcile,
Readiness, and Provider suites passed **11**, **15**, and **34**, and all **5** alias compile-fail
fixtures rejected the forbidden constructions. The combined WSL wall/model/config/native command
`cabal test hostbootstrap-core-test --ghc-options=-Werror --test-options="-p WslGlobalWall"` passed
**30/30**, including the Windows-native subset (**5/5**). `git diff --check`, the no-`.log` scan, and LF
checks were clean. This evidence is intentionally focused: a direct threaded invocation of the complete
test executable aborted with a generated-code access violation, and its leftover generated ownership
directories contaminated a subsequent `CLISpec` retry. No new complete-suite result is credited; a clean
sequential canonical core gate remains required before this tranche can be promoted.

**Validation evidence (2026-07-28, portable host wall):** `cabal build all --ghc-options=-Werror` and
the complete core suite `cabal test all --ghc-options=-Werror` pass at **520/520** on the Linux host,
including the new **20**-case `WslGlobalWallHostSpec`; the demo suite passes **105** with its embedded
core **520**. `fourmolu --mode check app src` is clean on the demo, `poetry run python -m
hostbootstrap.check_code` (ruff/black/mypy) is clean, and `poetry run python -m hostbootstrap.test_all`
passes **227**. The canonical container gate ran for real: `docker pull` of the published
`tuee22/hostbootstrap:basecontainer-cpu-amd64` followed by
`docker build -f demo/docker/Dockerfile` executed `RUN hostbootstrap-demo check-code` — the in-container
`fourmolu`/`hlint`/`cabal -Werror` gate — to success against these changes. That build then stopped at the
Halogen `spago build` step, which consumes bridge sources a bare `docker build` does not stage (the chain
generates them in the build-image step); this is the manual-invocation boundary, not a regression. No
native Windows or Apple run is claimed.

**Validation evidence (2026-07-27, guest-alias backend):** `cabal build all --ghc-options=-Werror` and the
**complete** core suite `cabal test all --ghc-options=-Werror` pass at **494/494** on the Linux host — a
clean sequential run (the test executable is not `-threaded` off Windows). `ProviderAliasSpec` grew to
**13** cases: the pure prepare/settle algebra plus new real-filesystem cases exercising
`discoverStrongAliasBackend` (mint vs. tool-absent `Unsupported`), create → own → conditional release
(the alias is unlinked), a foreign-repointed alias refused as a structured `Conflict` and left intact, and
a non-symlink occupant reported foreign — all through the real `flock`/`stat`/`ln`/`unlink` protocol on the
host filesystem. The five alias compile-fail fixtures still reject the forged
backend/prepared-call/observed-only/foreign-handle/cross-receipt constructions. `fourmolu`/`hlint` validate
only in the container `check-code` on this host (the host `fourmolu` is a non-canonical version). This does
**not** close the sprint: the WSL2 host `.wslconfig` wall Win32 port and C-shim retirement, the demo
`ln -s` / `.bak` production migration, and the native WSL2/Lima gates remain open.

**Dependency finding 2026-07-30 — the demo `ln -s` migration is Sprint 16.6-gated, and this is
structural rather than a scheduling preference.** `00-overview.md` item 1 named this migration the next
phase-ordered dependency root; tracing the actual type obligations shows it is not reachable from the
current plan surface. `runPreparedGuestAliasCall` needs the `PreparedGuestAliasCall` that
`withPreparedGuestAliasCall` mints, which requires a **`Managed`** durable-share handle. The only
producers of a `Managed` handle are `Reconcile.completeReconcile` / `completePreparedUnchanged`, both of
which consume a `PreparedOperation` for the share; `withPreparedOperation` in turn refuses unless the
supplied dependency observations are **exactly** the plan's ordered dependency set for that step. Two
facts then close the path:

- `Step.stepDependencies` is the whole preceding prefix, so `core:copy-source`'s dependency set contains
  every step before it, not just `core:deploy-vm`;
- a `DependencyObservation` requires a `PlannedResource`, and `Reconcile.plannedKindAccepts` is a
  **closed** table over `core:deploy-vm`, `core:copy-source`, `core:ensure-docker`,
  `project:deploy-minio`, `project:deploy-registry`, and `core:deploy-kind`. The demo's own
  `project:hostbootstrap-demo:ensure-vm-provider` step precedes `deploy-vm` and has no planned-resource
  family, so no observation for it is constructible.

The demo therefore cannot mint a `Managed` share today without either reordering `ensure` after the VM
launch (semantically wrong — the provider must exist before a VM is launched) or teaching core the
demo's project step keys (a § BB violation). The correct producer is the **plan-owned dependency-snapshot
traversal** of `development_plan_standards.md` § CC — "its internal dependency-snapshot traversal looks
up the exact managed resources and runs the plan-owned probes for the complete ordered zero/one/many edge
set" — which `Sprint 16.6` owns. The demo also carries no `copy-source` step at all today (the share is
created inside the `deploy-vm` action), so the migration additionally needs the plan node 16.6 introduces.

This sprint's own deliverable — the backend that holds the four § EE clauses for a provider-guest alias —
is landed and tested. What is open here is its **call-site adoption**, and that call site does not exist
until Sprint 16.6 builds it. The sprint's status is unchanged (`Active`); its `Blocked by` edge for this
item is now stated explicitly rather than implied by the "tranche-owned" note in the README.

**Update 2026-07-30 — the first of the two obstructions is gone; the second is now the binding one.**
Sprint 16.6 landed the plan-owned dependency-snapshot traversal, and with it the resource-bearing edge
set: `core:copy-source`'s dependency set on a demo-shaped plan is now exactly `["core:deploy-vm"]`, so
`project:hostbootstrap-demo:ensure-vm-provider` no longer demands an unconstructible observation. The
`copy-source` step constructor also already exists (`Step.copySourceStep`). What still blocks the demo
migration is narrower and was not visible before: a chain step's action is `HostConfig -> IO ()`, so it
receives no `LifecyclePlan` and cannot mint the `Managed` durable-share handle
`withPreparedGuestAliasCall` requires. That is Sprint 16.6's open item 3 (the single `ProjectPlan`
representation), which is where § U's replacement of the result-free step signature lives. Item 3's
descent half landed 2026-07-30 and does **not** lift this block: it gives a step the boundary it
descends through, not the plan its action runs against.

**Blocked by (this item only)**: Sprint 16.6, open item 3.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/wsl2.md` - the Windows WSL2 host provider: `ensure wsl2`, the
  production-selected install route, `wsl -d <distro> --`,
  `wsl --terminate`, `wsl --shutdown`, guarded `wsl --unregister`, and the
  `wsl2SizingArgs` budget cordon (the `.wslconfig` + VHDX wall), with a WRONG/RIGHT pair (WRONG: bare
  `$PATH` `wsl` / unguarded `wsl --unregister`; RIGHT: resolved `AbsExe` / name-prefix-guarded destroy).
  The deleted `wsl --import` alternative is historical, not a supported route.
- `documents/engineering/incus.md` - the host-provider axis, the `ensure incus` install, the VM lifecycle
  and `incus exec` dispatch, the reboot reconcile, and the `incusSizingArgs` budget cordon, with a
  WRONG/RIGHT pair (WRONG: bare `$PATH` `incus` / unguarded `incus delete`; RIGHT: resolved `AbsExe` /
  name-prefix-guarded destroy).
- `documents/engineering/lima.md` - the Apple Silicon Lima VM provider used by the worked demo,
  cross-referencing the WSL2 Windows peer (`wsl2.md`).

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` - the single `SubstrateProvider`/`Lift`
  parameterization of local, provider-backed `InVM`, and container frames, including WSL2 on Windows.
- `documents/architecture/durable_state.md` - the per-substrate host↔guest transfer table and the share
  primitive Sprint 11.8 adds; the canonical home for what `.data` does and does not guarantee.
- `documents/architecture/readiness.md` - **(new)** the `Ready`-witness readiness discipline that gates the
  mount/alias steps (Sprint 11.9) and the legible-failure contract, cross-referenced by the provider docs.

**Operations docs to create/update:**
- `documents/operations/demo_runbook.md` - the demo's Windows/WSL2 provider path alongside the Lima/Incus
  paths (provider-parameterized; no demo code change).

**Cross-references to add:**
- `documents/engineering/ensure_reconcilers.md` adds the `ensure incus` and `ensure wsl2` rows.
- `system-components.md` records the single `HostBootstrap.Substrate.Provider`/`HostBootstrap.Lift`
  route and adds `HostBootstrap.Incus`,
  `HostBootstrap.Ensure.Incus`, `HostBootstrap.Wsl2`, `HostBootstrap.Ensure.Wsl2`, the `Wsl` host tool,
  and the `ensure incus` / `ensure wsl2` reconciler rows.
- `development_plan_standards.md` § U records WSL2 as the Windows VM-provider peer of Lima/Incus.
