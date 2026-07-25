# Phase 16: Project lifecycle command

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [00-overview.md](00-overview.md), [README.md](README.md)

> **Purpose**: Build the `Step` algebra, recursive/fractal chain interpreter, and
> `project init|up|down|destroy` lifecycle command, then replace the current independent
> `psChain`/`psFrameContext`/`psTeardown` views with one opaque lifecycle plan (§ W, § Y).

## Phase Status

**Status**: Active

The target is one typed lifecycle plan, but the current extension contract still supplies `psChain`,
`psFrameContext`, and `psTeardown` independently. Forward execution is chain-driven while topology lookup
and reverse cleanup can disagree with it. Sprint 16.6 owns the unification as well as receipt-driven
recursive teardown; the pure `[Step]` single-representation claim is therefore not yet fully enforced.

**Reopened then closed (2026-07-05, cross-substrate reliability hardening).** The demo real-run gate surfaced
lifecycle-interpreter gaps in this phase's scope: `applyChain` has no `bracket`/`finally`, so a chain
failure during `project up` leaks every provisioned resource (leftover VM + in-VM kind + `.wslconfig`) with
no best-effort teardown; and the `down`/`up` idempotency + kind-recreate contract does not hold for the
VM-nested topology (with [Phase 5](phase-5-cluster-lifecycle-and-resource-cordoning.md)). The fixes landed
(see `## Remaining Work`) and **closed 2026-07-05** by a live Windows/WSL2 `test run all` reporting
**`6/6 passed`** — the guarded `applyChain` root-frame teardown was exercised repeatedly on the iteration
runs (each observed caught failure ran the same best-effort `project destroy`, and that dated lane left no
observed VM/kind/`.wslconfig`), and the successful run drove the recursive descent end-to-end on both
message variants. That result did not prove interruption safety, exact ownership, or teardown of every
possible partial descendant; Sprint 16.6 owns those properties.

**Reopened (2026-06-19) and closed (2026-06-20)** to make the command surface **fixed and closed** —
`project` / `test` / `service` / `context` / `check-code`, with `ProjectSpec` carrying no `ProjectCommand`
deltas and `hostbootstrap-core` framed as a library of composable tools. The closure is real-run-validated:
the fixed surface drove the full `project up` lifecycle + `test run all` (`3/3 passed`) end-to-end on a 16
GiB Apple-Silicon host (2026-06-20, [phase-13](phase-13-hostbootstrap-demo.md)); `project up` / `project
destroy` ran on Apple Silicon and the full `project down` / `up` / `destroy` set on Incus/Linux (2026-06-18)
with the pure VM-stop/destroy argv unit-tested (`IncusSpec` / `LimaSpec`). See `## Remaining Work` for the
delivered surface closure.

This phase owns the **new** surface the "chain is the project" model targets: the `Step` algebra, the
recursive interpreter, and the `project` lifecycle command, built on the reopened substrate phases —
phase-4 (the composable optparse command tree and entrypoint, § P), phase-5 (the cluster bring-up/teardown
reconcilers the chain interprets as steps), phase-14 (the self-reference lift generalized into the recursive
`project up` interpreter framing, § U), and phase-15 (the binary-context contract the per-frame fail-fast
handoff rests on, § X).

**Historical Sprint 16.1–16.4 evidence (2026-06-18):**
a single `project up` drove the full recursive descent — `host-orchestrator-0` (provision VM, build pb #2 +
image #3) → `vm-orchestrator-1` (`incus exec` handoff, mint the child config) → `vm-project-container-2`
(`docker run` handoff: `deploy-kind` → `deploy-harbor` (the full 8-pod production Harbor) → `push-image` (the
20GB image to the in-cluster registry) → `deploy-chart` → `expose-port`) — to a **live persistent stack**
(the webservice serving HTTP 200 on `localhost:30080`), then `project down` / `project destroy` tore it down
with the plan's `.data` path outside both teardown removal sets (§ Y). That dated run proved the removal-set
invariant, not the later durable-share transport. The demo now creates `.data` at the host project root
and carries it through the provider share/alias and nested mounts, outside the provider disk; only the
dedicated destroy → up → read-back proof remains open in Phase 5 Sprint 5.6. The `Step` algebra (16.1), the
recursive interpreter + multi-frame descent (16.2), the `project init|up|down|destroy` command (16.3),
and the demo chain migration incl. dissolving the
old `deploy` / `harbor` / `role` verbs + the Op-based `HostBootstrapDemo.Chain` (16.4) all landed. The core
tree carries only `coreCommandNames` = `context` / `project` / `test` / `service` / `check-code`; `ensure`
is a reconciler library composed through `ensure-*` steps, not a verb. The flat `cluster`, `config init`,
`config show|schema|render`, and `context create` verbs are removed; the demo contributes
`demoChainFor :: Substrate -> ProjectConfig -> [Step]` + `demoFrameContext` + `demoTeardown`, with its old per-project
Harbor names retained here only as historical run evidence and its removed verbs recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The current demo uses registry/MinIO
steps; Phase 13.18/21.4 remove stale Harbor metadata. Sprint 16.6 reopens lifecycle closure for
receipt-driven recursive teardown.

Forward-pointer: under the generic project model, `project init` sources its defaults from the
project-supplied `psInit` (core owns no default config values) and layers optional flag overrides over
them. That parameterization is owned by
[phase-19-generic-project-model.md](phase-19-generic-project-model.md); the `project init|up|down|destroy`
surface this phase shipped is unchanged.

**Reopened 2026-07-09 for accelerator daemon lifecycle.** Host-resident Apple Silicon and Windows GPU
accelerator daemons must start only after `project up` has exposed the web service's local-only ingress,
and must be stopped by `project down`/`project destroy`. Linux GPU also needs a direct host `nvkind` path
that skips the Incus VM.

## Remaining Work

**One lifecycle plan and recursive teardown ownership — open (Sprint 16.6).** Derive topology, forward
execution, and reverse teardown from one typed plan; carry its typed acquisition ledger through descent and
unwind exactly the owned resources in reverse order on failure, interruption, down, and destroy. Plan,
handles, and receipts retain the Production-or-exact-Harness lifecycle scope across each recursive
self-invocation, which consumes Phase 10.9's authenticated one-time handoff before authority is rehydrated.

**Accelerator lifecycle work — implementation complete; live gates open.**

- Done statically: `HostBootstrap.Step.PostHandoff` / `postHandoffStep` and the `HostBootstrap.Chain`
  pre/post split run host-frame post-handoff hooks only after the recursive child frame returns
  successfully. The demo contributes a host-frame accelerator-daemon hook after `expose-port`, so
  Apple/Windows host daemon startup is ordered after the web accelerator ingress is reachable.
- Done statically: the demo now selects `demoChainFor` by detected substrate. `linux-gpu` skips the Incus VM
  and uses a direct host -> project-container chain with the Phase 15 direct Linux GPU context and the
  Phase 5 `NvkindDriver` plan; `linux-cpu` keeps the existing Incus VM-backed chain.
- Done statically: Apple Silicon and Windows GPU use a host-native project-binary build and run path. The
  post-handoff hook copies that host-native binary into `.build/accelerator-daemon/`, writes its
  daemon-authority sibling config, and launches config-selected `service run` with
  `HOSTBOOTSTRAP_ACCELERATOR_WS_URL`. It does not return until a readiness marker proves worker build plus
  WebSocket connection, using a 30-minute pristine-install budget while repeatedly checking exact process
  identity. Process ownership is fail-closed: strict pid parsing, symmetric pid/owner markers, an absolute
  executable-plus-argv identity, masked acquisition, a shutdown sentinel, no inherited output streams,
  singleton replacement, and idempotent teardown are unit-tested.
- Done statically: the Linux CPU and Linux GPU chains generate/apply their daemon ConfigMap, deploy and
  rollout-wait an in-cluster daemon Deployment that dials the web service's distinct accelerator
  configured `ClusterIP`, and fingerprint config bytes for rollout. A connection-owned readiness marker
  makes rollout wait for the built worker and live WebSocket; `Recreate` prevents peer overlap. The GPU workload requests one
  `nvidia.com/gpu`.

Dated validation evidence (2026-07-15): `cabal build all --ghc-options=-Werror` and `cabal test all` passed from
`core/` (364 tests); the demo `-Werror` build and test run pass with 87 demo tests plus the embedded
364-core suite. That is dated accelerator evidence. Sprint 16.6 additionally owns typed recursive
teardown; accelerator-lane work still must prove the host daemon connects through the
local-only NodePort, prove the native Linux CPU/GPU daemon Deployments connect through `ClusterIP`, and run
the implemented browser Add assertion as part of the four-case/two-variant `8/8` gate. The dated Windows
GPU/WSL2 `8/8` accepted by Phase 18 proves that host-daemon lane; it does not exercise Phase 16.6's
future typed recursive teardown or close the remaining native Linux and Apple lanes.

**Previously closed 2026-07-05 — lifecycle-interpreter reliability:**

- **Best-effort teardown on chain failure — landed.** `applyChain` now `try`-wraps `runChainFromFrame`, and a
  chain failure (a `Left` from a non-zero handoff, or a thrown exception) at the **root** frame runs the same
  best-effort teardown as `project destroy` (`clusterDelete` + `teardown … True`, each exception-swallowed)
  before dying. This attempts to remove the VM/in-VM kind/global `.wslconfig`, but swallowed cleanup
  failures and unvisited descendants mean it is not a no-leak guarantee. Only the
  root frame (`null parentChain`) tears down — a nested frame's failure propagates up to the root, which alone
  can reach the VM to delete it. After an uncatchable external kill, the next `project up` performs the
  existing best-effort stale-state probes; it is not a receipt-backed recovery guarantee
  (`HostBootstrap.Command` `runUp`/`applyChain`, paired with
  [Phase 5](phase-5-cluster-lifecycle-and-resource-cordoning.md) /
  [Phase 11](phase-11-incus-host-provider.md)).
- **Reconcile the `down`/`up` + kind-recreate contract — landed (via Phase 5).** `project down` stops the VM
  (leaving its in-VM kind cluster stopped), and the next `project up`'s in-VM `clusterCreate` health-checks the
  listed-but-unhealthy cluster and recreates it (the [Phase 5](phase-5-cluster-lifecycle-and-resource-cordoning.md)
  health-check-and-recreate). This recovered the dated VM-nested stopped-stack path; it is not universal,
  ownership-preserving idempotence.

Code-check gate (2026-07-05): `cabal build all --ghc-options=-Werror` + `cabal test all` (292) green from
`core/`; the demo `-Werror` build green. **Closed (real-run, § C, 2026-07-05):** the root-frame best-effort
teardown fired on every caught chain failure during the iteration runs (no leaked VM/kind/`.wslconfig`), and
the successful Windows/WSL2 `test run all` **`6/6`** run drove the recursive descent end-to-end on both
variants. **None remaining in that dated best-effort scope;** Sprint 16.6 owns the stronger current
contract.

Close the command surface to the fixed core set and make `hostbootstrap-core` a **library of composable
tools**, not a CLI topology (development_plan_standards § P, § T).

**Landed in code (2026-06-19), code-check-validated** (`cabal test all` green; `cabal build all
--ghc-options=-Werror` green; fourmolu/hlint clean on the demo; verified on the real binary that
`hostbootstrap-demo --help` lists only `context` / `project` / `test` / `service` /
`check-code`):

- The surface is exactly `project` / `test` / `service` / `context` / `check-code` for every project binary.
  The `ProjectCommand` / `projectCommand` / `psCommands` extension point is **removed** from
  `HostBootstrap.CLI`; a project extends core only through the streams (lift chain, Dhall vocabulary,
  schema-gen, test suite, service handlers — `withChain` / `withFrameContext` / `withTeardown` /
  `withServices`). `runHostBootstrapCLI` no longer merges project command mods.
- The residual demo `vm` / `incus` / `web` project verbs are **deleted** (`demoCommands` is gone); their IO
  is retained as the chain-step library functions `runVmEnsure` / `runVmUp` / `runVmBootstrap` /
  `ensureIncusProvider` and the `web` 'ServiceHandler' / build-image bridge codegen
  ([legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).
- The build-time `web bridge` is **re-homed into the build-image chain step** (`runVmBootstrap` runs
  `writeBridge` before the image build; the Dockerfile no longer invokes a `web bridge` verb).
- The `service` command it slots into is owned by [phase-18](phase-18-service-runtime-command.md).

Remaining (real-run-gated, § C): the fixed surface exercised by the full demo `project up` run
([phase-13](phase-13-hostbootstrap-demo.md)).

## Phase Objective

Make a project's deploy a pure value interpreted by the core, per development_plan_standards § Y:

- Define the `Step` algebra as the lift-chain stream's reuse unit (§ T): `hostbootstrap-core` ships the
  host-management step kinds (deploy-VM, `ensure-*`, copy-source, build-pb, build-image, `context-init`,
  deploy-kind, deploy-chart, expose-port), and a project contributes its own step kinds (deploy-registry,
  push-image) into the same `[Step]`. Host and project steps interleave freely.
- Interpret the chain **recursively/fractally**: `project up` runs the current frame's steps, then for the
  next nested frame provisions it, builds/installs the project binary in it, and hands off `pb project up`
  (the fractal bootstrap, § U), so each binary owns its own segment and the command can be invoked at any
  declared frame. Convergence after partial failure is currently best-effort; Sprint 16.6 owns durable
  restart recovery.
- Surface the lifecycle command `project init|up|down|destroy` on the core optparse tree (§ P), with
  `project up --dry-run` rendering the current pure `chain cfg` forward ordering; Sprint 16.6 replaces
  the independent topology/teardown inputs with the complete single representation (§ W).
- Hold the doctrine that the sibling `<project>.dhall` carries **parameters + context + witness**, never
  the chain shape; each frame verifies it is in the frame its `<project>.dhall` describes, or fails fast
  (§ X); optional structural variation (skip the VM, deploy straight to Docker) is a root-`<project>.dhall`
  flag so the chain stays a pure function of root parameters.
- Add the VM stop-without-delete capability and cluster-frame teardown semantics. `project down` may
  delete an ephemeral Kind cluster because Kind has no reliable stop/restart operation, but it does not
  delete durable roots or provider frames/disks; `project destroy` additionally deletes owned provider
  frames and disks. The demo's `.data` is already created at the host project root and carried through the
  provider share/alias and nested mounts, so it lives outside the provider disk and both teardown plans.
  The only open durability requirement is Phase 5 Sprint 5.6's live write → `project destroy` →
  `project up` → read-back proof
  ([durable_state](../documents/architecture/durable_state.md)).

## Sprints

### Sprint 16.1: The `Step` algebra [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`, `core/hostbootstrap-core/test/StepSpec.hs`, `core/hostbootstrap-core/hostbootstrap-core.cabal`
**Docs to update**: `documents/architecture/library_hierarchy.md`, `documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/composition_patterns.md`

#### Objective

Define the `Step` algebra as the lift-chain stream's extension seam (§ T): a closed core set of
host-management step kinds plus an open seam for project-contributed step kinds, all carried in one
`[Step]` value.

#### Deliverables

- A `Step` type in `HostBootstrap.Step` whose core constructors model the host-management step kinds:
  deploy-VM, `ensure-*` (the `ensure` reconcilers invoked as chain steps, § L), copy-source, build-pb,
  build-image, `context-init`, deploy-kind, deploy-chart, and expose-port.
- A project-extension seam so a consumer contributes its own step kinds (for the demo: deploy-registry,
  push-image) into the same `[Step]` without redefining the core kinds, interleaving host and
  workload steps freely (the lift-chain stream, § T).
- A pure, unit-testable shape for each step (description, target frame, and reconcile action) so the chain
  is a value that renders without acting.

#### Validation

- Unit tests in `StepSpec` proving each core step kind renders its pure description, a project step kind
  composes into the same `[Step]`, and host and project steps interleave in chain order.
- `cabal test all` from `core/` passes with `StepSpec` included.

#### Remaining Work

None. `HostBootstrap.Step` ships the `Step` type, the closed core `StepKind` set plus the open
`ProjectStep` seam, the pure `renderStep` / `renderChainPlan` dry-run render, and the `stepsForFrame` /
`chainFrames` frame-segmentation helpers, with a per-kind constructor for each host-management kind.
`StepSpec` proves each kind renders its stable name, a project step interleaves with host steps in chain
order, and frame segmentation selects a frame's steps in order. The demo's hand-written `demoDeployChain`
that this supersedes is migrated in Sprint 16.4.

### Sprint 16.2: The recursive/fractal chain interpreter [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`, `core/hostbootstrap-core/test/ChainSpec.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/src/HostBootstrap/Context.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`, `documents/engineering/dhall_topology.md`

#### Objective

Interpret a pure `chain :: cfg -> [Step]` value recursively across the composed frame stack, so
each binary owns its own segment and the command can be invoked at any declared frame (§ U, § Y).
Convergence after a partial failure remains best-effort until Sprint 16.6 lands the durable
identity-bound journal and recovery model.

#### Deliverables

- A recursive interpreter in `HostBootstrap.Chain` that, for the current frame, runs this frame's steps,
  then for the next nested frame provisions it, builds/installs the project binary in it, and hands off
  `pb project up` — the fractal bootstrap's three beats (provision the frame, build the pb in it, hand off
  `pb project up`), of which the Python bootstrapper is the metal-frame instance (§ M, § U).
- A per-frame fail-fast guard on the handoff: before a frame acts, its copy of the binary verifies its
  local witnesses prove it is in the frame its `<project>.dhall` describes, or exits 1 (§ X).
- The then-current `context-init` step's reconcile action: mint the callee's child `<project>.dhall` (parameters +
  context + witness, never the chain shape) from the active parent config just before the recursive handoff
  into the next frame, re-homing the dissolved `context create vm|container|service` mutation verb (§ X,
  phase-15).
- Initial restartability: a `project up` re-run probes and reuses selected existing state. This is
  best-effort and not receipt-preserving idempotence; Phase 9.10 and Sprint 16.6 own total reconcile
  outcomes, exact instance identity, and safe recovery of partial stacks.

#### Validation

- Unit tests in `ChainSpec` proving the argv fold for the recursive handoff is pure (§ K: only the
  outermost host dispatch names a resolver-mapped absolute path; every nested tool is the target's own bare
  `$PATH` name), the per-frame fail-fast rejects a wrong-frame witness before side effects, and the
  then-current `context-init` path derives a child config that names the next frame.
- A dry-run test proving the representative valid fixture is rendered from the same `chain cfg` value
  the interpreter consumes. This does not prove global render/effect order equivalence for currently
  accepted noncontiguous `A → B → A` frame sequences.
- `cabal test all` from `core/` passes with `ChainSpec` included.

#### Remaining Work

The pure interpreter core is implemented and unit-tested (`HostBootstrap.Chain` + `ChainSpec`):
`renderChain` (the `--dry-run` plan), `nextFrameAfter` (the descent order), `handoffDispatch` (the
recursive `project up` argv fold over `HostBootstrap.Lift.foldLift`, honouring § K), the effectful
`runChainFromFrame` seam (run this frame's steps, then hand off `project up` into the next frame, fail-closed
on a non-zero handoff), all sourced from the same forward list. Current first-frame grouping can still
make rendered and effect order differ for an accepted noncontiguous frame sequence; Sprints 19.8 and
16.6 own validated-plan rejection and exact projection equivalence. The **multi-frame recursive
descent is now real-run-validated on Incus/Linux**: a real `project up` ran the metal segment (provision VM →
build pb #2 → build image #3), then the metal→VM handoff (`incus exec <vm> -- /usr/local/bin/hostbootstrap-demo
project up`) and the VM→container handoff (`docker run <image> project up`) both **succeeded** — the
then-current `context-init` path minted the `vm-project-container-2` child config (`deriveContainerContext` /
`writeProjectConfigFile`), the per-frame fail-fast gate accepted each frame's runtime witnesses
(`/run/hostbootstrap/vm-provider`, docker.sock, `HOSTBOOTSTRAP_CURRENT_FRAME`), and `project up` re-entered
the interpreter in the nested frame (gating as `ClusterLifecycleCommand`, the class allowed in all three
orchestration kinds — a real gating bug fixed here: it previously gated as `HostOrchestratorCommand`, rejected
in the VM/container frames). **None remaining — the full recursive descent ran end-to-end on Incus/Linux
(2026-06-18):** a single `project up` exited 0 having driven the container-frame **workload** apply
(`deploy-kind` → `deploy-harbor` (the full 8-pod production Harbor) → `push-image` (the 20GB image to the
in-cluster registry) → `deploy-chart` → `expose-port`) to a **live persistent stack** — `localhost:30080`
serving the webservice (HTTP 200), the Harbor registry on `localhost:30500`. The interpreter also prints a
nested frame's captured stdout on failure now, so the recursive workload is observable in the run log.

### Sprint 16.3: The `project init|up|down|destroy` lifecycle command [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/cluster_lifecycle.md`, `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/operations/demo_runbook.md`

#### Objective

Surface the recursive lifecycle command `project init|up|down|destroy` on the core optparse tree (§ P) and
drive the chain interpreter from it.

#### Deliverables

- `project init` — a config-free writer. With no flags it writes a fresh executable-sibling
  host-orchestrator root and refuses an existing output. Its current shared parser also accepts `--role`,
  repeatable `--also-role`, `--output`, `--force`, `--if-missing`, and optional
  `--cpu` / `--memory` / `--storage` / `--ha-replicas`; those modes mean the current command is not
  absolutely fresh-root-only. Phase 17 Sprint 17.4 owns the exact target parser/overwrite semantics, and
  Phase 15 Sprint 15.9 owns opaque role compatibility and authority. Python does not trigger init after
  the host-native build (§ M); the Dockerfile build-time authority surface is the `project init`-family
  equivalent of the former `config init --role image-build-container`, still baked before `check-code`
  (§ R, phase-15).
- `project up` — interprets the chain recursively from the current frame (Sprint 16.2); its current
  best-effort probes reuse selected state, while receipt-preserving idempotence remains Sprint 16.6 work.
  `--dry-run` renders the pure `chain cfg` `[Step]` value without acting (§ W).
- `project down` — stops service/VM frames and deletes kind clusters; the **cluster plan's**
  `teardown Down` removal set is empty, so it does not enumerate a cluster data path for removal. That
  narrow invariant does not claim that every provider hook performs no filesystem maintenance: the
  Windows provider stop path may restore/remove the generated `.wslconfig` and its backup.
  VM frames use the provider stop-without-delete capability (incus/Lima **stop**, not destroy); kind clusters
  are ephemeral and may be deleted because Kind has no reliable stop/restart contract. `down` does not
  delete durable host roots or provider frames/disks. Current cleanup is best-effort and reconstructs from
  root callbacks; it does not guarantee that every owned descendant of a partial stack is reached.
- `project destroy` — directly performs delete-mode cluster cleanup and the delete-mode project/provider
  hook, whose semantics encompass stopping and deleting the provisioned frame and disk
  (`incus delete --force`, `limactl delete --force`, `wsl --unregister`); it does not invoke the separate
  `project down` route first. The demo now creates
  `.data` at the host project root and carries it through the provider share/alias and nested mounts, so
  the durable root is outside that provider disk as well as absent from every teardown removal set. The
  transport is implemented; Phase 5 Sprint 5.6's live destroy → up → read-back assertion is the only open
  durability proof — see [durable_state](../documents/architecture/durable_state.md).
- Command gating: within the `project` group, `project init` is the config-free writer and every other
  project verb gates through the sibling `<project>.dhall`. The other command groups' config-free
  writers/static routes and file readers follow the exact § X matrix; “read-only `context`” does not mean
  every context route is config-free. Project commands cannot shadow these core verbs (§ P).

#### Validation

- `LifecycleSpec` unit tests proving the pure teardown partition — `teardown Down` returns an empty removal
  set, `teardown Delete` returns only the derived paths, and the data path is in every preserve set — plus
  the on-disk teardown cases, which create a real `.data` directory in a temporary root and run the real
  `clusterDown` / `clusterDelete` drivers: after `clusterDown` both the data path and the derived paths
  still exist (the removal set is empty), and after `clusterDelete` the data path still exists while the
  derived paths are gone. Those tests prove the removal-set invariant; the live host-root
  destroy → up → read-back proof remains Phase 5 Sprint 5.6.
- `CLISpec` unit tests proving `project up --dry-run` renders the pure chain through the context gate and
  `project up` fails fast without a sibling context; `ContextSpec` covering `project init`.
- `IncusSpec` / `LimaSpec` argv tests proving `project down` issues stop-not-delete (`stopVMArgs`) and
  `project destroy` issues the guarded delete (`destroyVMArgs` / `deleteVMArgs`) to the VM provider.
- Tests proving the lifecycle verbs gate through the active context and are accepted only in contexts that
  authorize them (§ X).
- `cabal test all` from `core/` and `cabal build all` from `demo/` pass.

#### Remaining Work

None for the command-surface sprint. The `project init|up|down|destroy` surface ships on the core optparse tree
(`HostBootstrap.Command.projectCommandGroup`), with the chain and the chain-frame teardown threaded through
`ProjectSpec` (`psChain` / `psFrameContext` / `psTeardown`, attached with `withChain` / `withFrameContext` /
`withTeardown`). `project up --dry-run` renders `chain cfg` through the context gate; the apply path
(`runChainFromFrame`) is **real-run-validated end-to-end on Incus/Linux** — a real `project up` provisioned
the VM, built the demo binary host-native in it (build #2, self-proved with `context schema`), and built the
project image FROM the published base in it (build #3), exiting 0. Current `project down` attempts
owning-current-frame cluster cleanup, then the teardown hook **stops** the VM (incus/Lima `stop`) —
validated in that dated lane leaving the VM `STOPPED`; `project destroy` similarly attempts current-frame
cluster deletion and then the hook **deletes** the VM/disk — validated there leaving the VM gone. Neither
command recursively visits every child. The pure argv contract
(`stopVMArgs` = stop-not-delete, guarded `destroyVMArgs` / `deleteVMArgs` = delete) is unit-tested in
`IncusSpec` / `LimaSpec`. Those dated successful runs do not establish universal partial-stack teardown or
receipt-preserving idempotence; Sprint 16.6 owns that closure. The flat `cluster` / `config init` /
`context create` verbs are already removed from
the core tree (`coreCommandNames` = `context` / `project` / `test` / `service` / `check-code`; no hidden
commands); the demo's own legacy `vm` / `harbor` / `web` / `deploy` / `role` / `incus` verbs are dissolved
with the demo chain migration (Sprint 16.4, tracked in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).

### Sprint 16.4: Demo chain migration onto the core interpreter [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`
**Docs to update**: `documents/engineering/authoring_project_binaries.md`, `documents/engineering/derived_project_standards.md`, `documents/operations/demo_runbook.md`

#### Objective

This is a historical delivery record: the named Harbor and noun-verb spellings below were subsequently
removed. The current replacement is the registry/MinIO workload expressed as steps in
`demoChainFor`, interpreted by the fixed `project` lifecycle.

Migrate the worked demo from hand-written orchestration verbs to a contributed `chain :: cfg ->
[Step]` value plus step actions interpreted by the core lifecycle command, demonstrating the
workload-extension seam (§ T, § Y).

#### Deliverables

- The demo contributes its chain value — host-pb → deploy VM (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows) →
  copy source + ensure GHC in the VM → build pb in the VM → ensure Docker in the VM → build the project
  image → deploy kind → deploy harbor → launch the webservice → expose the NodePort to the host — as a
  `[Step]` value, interleaving core host-management steps with the demo's own deploy-harbor /
  push-image step kinds.
- The demo's project step actions (registry install, web-serve, role) are expressed as steps in the chain,
  not as separate top-level verbs; the demo `deploy` / `vm` / `incus` / `harbor` / `web` / `role` verbs and
  the hand-written `demoDeployChain` are dissolved (phase-13).
- The demo's `ProjectSpec` names its chain value as its primary CLI contribution (§ P), alongside its
  non-empty test suite, `check-code` action, and `ConfigArtifact` delta.

#### Validation

- A `DemoChainSpec` dry-run test proving `project up --dry-run` renders the demo's full `[Step]` chain in
  the expected order, with the per-frame context gate preserved by the recursive interpreter's per-frame
  fail-fast.
- `cabal build all` from `demo/` passes; the in-image fourmolu/hlint and `check-code` gates pass for the
  demo.
- A real-run-gated `project up` on a closed provider path (Lima on Apple Silicon, Incus on Linux) brings
  up the persistent stack and a follow-on `test run all` validates it (the decoupled test surface, § Z,
  phase-17). The Windows WSL2 provider follows the same chain shape but its real provider closure remains
  Phase 11 Sprint 11.7 work.

#### Remaining Work

The metal-frame migration is **done and real-run-validated**: the demo contributes
`demoChainFor :: Substrate -> ProjectConfig -> [Step]` (`demo/src/HostBootstrapDemo/Commands.hs`), wired via `withChain` (and
the chain-frame teardown via `withTeardown`) in `demo/app/Main.hs`, and a real `hostbootstrap-demo project
up` on Incus/Linux ran the chain's three metal-frame steps end-to-end — ensure the VM provider → launch the
budget VM (cordon #1) → pristine-bootstrap (build #2 host-native + build #3 project image in the VM) —
exiting 0, with `project down` / `project destroy` stopping / deleting the VM (the cluster teardown's removal
set never names the data path, § Y). That historical run predates the now-implemented host-root
share/alias carry and therefore is not the still-open destroy → up → read-back proof.
`project up --dry-run` renders the chain and `context inspect` renders the composition. The user chose
(2026-06-17) the maximalist target: `project up` ends at a **persistent full stack**, descending **three
frames** (`host-orchestrator-0` → `vm-orchestrator-1` → `vm-project-container-2`, each a real handoff). The
container-frame migration is landing in code-check-validated increments:

- **Increment 1 (Done, code-check-gated):** the demo chain now renders the full 3-frame interleaved value —
  metal (`deploy-vm` ×2, `build-pb`) → `vm-orchestrator-1` (`context-init`) → `vm-project-container-2`
  (`deploy-kind`, `deploy-harbor`, `push-image`, `deploy-chart`, `deploy-role`, `expose-port`). The per-frame
  lift-context resolver `demoFrameContext` is wired via `withFrameContext` (metal→VM folds to `incus exec`,
  VM→container to a local `docker run`); the container-frame actions are loud `pendingContainerStep` stubs.
  Validated: `cabal build all --ghc-options=-Werror`, `project up --dry-run` renders the steps in frame
  order, fourmolu + hlint clean via the base image. The validated metal frame is untouched.
- **Increment 2 (Done, code-check-gated):** the container-frame actions are now **real** (no longer stubs).
  Core `clusterUp` is split into exported `clusterCreate` (kind + cordon) + `deployChart` so the chain can
  interleave registry setup between cluster creation and the chart (`HostBootstrap.Cluster.Lifecycle`, 220
  core tests still green). The demo's six container-frame steps drove the then-current `context-init` path (mint the
  `vm-project-container-2` child config via `deriveContainerContext` + `writeProjectConfigFile` to where
  `demoDeployImage` mounts it), `deploy-kind` (`clusterCreate`, Production profile), `deploy-harbor` (the
  Helm Harbor install, NodePort 30500), `push-image` (`kind load` + Docker push to Harbor), `deploy-chart`
  (`deployChart` — the web pod), and `expose-port` (`waitNodePort` readiness on 30080). Validated:
  `cabal build all --ghc-options=-Werror`, the 9-step dry-run, fourmolu + hlint clean.

- **Increment 3 (Done, real-run-validated 2026-06-18):** a single `hostbootstrap-demo project up` ran the
  whole 3-frame chain end-to-end on the live Incus VM (exit 0) to a **live persistent full stack** —
  `deploy-kind` (cordoned cluster, kind `extraPortMappings` via a `demo/kind.yaml`, `kind export kubeconfig`)
  → `deploy-harbor` (the full **8-pod production Harbor**, `helm --wait`) → `push-image` (`docker login` + the
  20GB image pushed to the in-cluster registry) → `deploy-chart` (`deployChart --wait`, the web pod) →
  `expose-port` (a direct in-container `curl` on the host network) → `localhost:30080` serving HTTP 200.
  `project down` stopped the VM and `project destroy` deleted it and its disk; the dated teardown also
  reported `kind delete cluster`, with the data path outside the removal set (§ Y). That result did not
  establish recursive reverse cleanup derived from the forward chain; Sprint 16.6 owns that target.
  Handoff plumbing landed: the build-#2 in-VM pb + its
  sibling `.dhall` install at
  `/usr/local/bin/hostbootstrap-demo`; the VM was sized above the cluster budget (`vmSizingWithHeadroom`,
  cordon #1 > cordon #2). The full Harbor + 20GB push fit once `docker builder prune` freed host disk.

- **Increment 4 (Done, 2026-06-18):** the legacy cleanup landed. `demo/src/HostBootstrapDemo/Chain.hs`
  (the Op-based `demoDeployChain` / `renderPlan` / `runDeploy`) and `HostBootstrapDemo.Role` are deleted; the
  `deploy`, `harbor` (`runHarborInstall` / `runHarborPush`), and `role` verbs are removed from `demoCommands`
  (now `[incusCmd, vmCmd, webCmd]`); the `containerRuntimeFrameId` / `vmRuntimeContainerConfigPath` constants
  moved into `Commands.hs`. The `web` verb **stays** (the chart pod's `args: ["web", "serve"]` and the
  Dockerfile's `web bridge` build step depend on it) and `vm` / `incus` stay as provider/VM debug hatches
  whose IO the metal chain steps reuse. Validated: `cabal build all --ghc-options=-Werror` (6 modules),
  `project up --dry-run` still renders the 9-step chain, the verb tree no longer lists `deploy` / `harbor` /
  `role`, fourmolu + hlint clean. Recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

None remaining. Optional future follow-ups (not gating): build #3 in the `vm-orchestrator-1` segment for the
purest fractal, role-as-pod folded into the chart, and `test run all` against the live persistent stack
(§ Z, [phase-17](phase-17-chain-driven-test-and-context-introspection.md)).

### Sprint 16.5: Accelerator daemon lifecycle hooks [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/engineering/accelerator_daemon.md`, `documents/operations/demo_runbook.md`

#### Objective

Extend the recursive lifecycle so accelerator daemons can be started in the correct frame after the web
accelerator ingress exists and stopped during teardown.

#### Deliverables

- A post-cluster/post-handoff hook or ordered step class that runs after the child frame has stood up the
  web endpoint.
- Host-daemon process lifecycle for Apple Silicon and Windows GPU, including pid-file singleton behavior,
  daemon-authority sibling config creation, and `project down`/`project destroy` stop behavior.
- Direct Linux GPU `nvkind` lifecycle through the project container without Incus VM provisioning.
- Preservation of the existing Linux CPU Incus path.

#### Validation

- Pure chain-order tests prove host daemon startup cannot run before the accelerator ingress exists.
- Demo chain-selection tests prove Linux GPU uses the direct host -> project-container `nvkind` chain while
  Linux CPU keeps the VM-backed chain.
- Process lifecycle tests prove daemon start/stop is idempotent and teardown-safe.
- Integration tests prove host daemons connect through local-only NodePort and in-cluster daemons connect
  through `ClusterIP`.
- Browser e2e add test proves the UI receives a daemon-backed result.

#### Remaining Work

Implementation and static validation are complete. Hook ordering and chain selection are covered; the
Apple/Windows host path builds and runs the project binary host-native, writes the daemon projection, and
launches config-selected `service run` only after `expose-port`. Its singleton lifecycle uses strict pid
parsing, an owner marker, exact executable-plus-argv identity, a shutdown sentinel, and no inherited output
streams, so stale or unrelated processes are never killed. The Linux CPU/GPU
`deploy-accelerator-daemon` step applies the dynamic daemon ConfigMap, deploys and rollout-waits the daemon
workload dialing the distinct accelerator `ClusterIP`, and requests one GPU on the GPU lane. Config hashes
roll subPath-mounted pods. The Windows worker path resolves the generated `.exe`, and build-#3 failures
stream their captured output. Dated static evidence is recorded above; no mutable current count is claimed.

Open only for real-run closure (§ C): execute the host-daemon lifecycle through the local-only NodePort,
execute the native Linux CPU/GPU in-cluster deployments, and run the implemented browser Add assertion in
the full four-case/two-variant harness. The accepted Windows GPU/WSL2 `8/8` closes its host-daemon lane,
but unavailable native Linux and Apple lanes still prevent this sprint's cross-substrate closure. That
run also predates and cannot close Sprint 16.6's typed plan/journal teardown contract.

### Sprint 16.6: Ownership-preserving recursive teardown [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 5.7, 9.10, 10.9, 15.9, and 19.7–19.8
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/architecture/harness_workflow.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make failure/down/destroy recurse through every frame actually acquired by the chain, in reverse order,
without reconstructing ownership or deleting foreign state.

#### Deliverables

- Thread Phase 9 lifecycle state and Phase 10 stable ownership records through recursive `project up`
  handoffs. Each process constructs its own opaque `ProjectPlan scope specDigest planId configId cfg` inside fresh
  `planId`/`configId` continuations. Only stable plan/config digests and frame/resource/generation/
  operation records cross a process; no `AcquisitionJournal scope planId`, handle, or receipt is
  transported. Fresh local bindings make two Production projects/runs unable to exchange state.
- Make each recursive self-invocation consume the authenticated, one-time
  token defined with Sprint 10.9, bound to exact scope/plan revision/broker generation/edge/child config
  digest/verb/phase. Immediate parents relay to the independently authorized root broker and receive no
  signing key. Grant+byte verification through the scope-correct project-owned
  `ProjectCodec scope specDigest cfg` yields
  the exact `VerifiedHandoff`, a fresh child config identity under the `ConfigHandoff` payload kind, and
  a validated config. Those values do not directly authorize dispatch:
  `withChildProjectPlan` consumes them, the closed verb, and
  `NonEmpty (PlanDraft scope specDigest (cfg scope))`, then jointly yields a fresh local
  `ProjectPlan scope specDigest planId configId cfg`,
  `PlanDigestBinding scope specDigest planDigest planId`, and exact `ChildPlanAuthority` inside a rank-2
  continuation. `authorizeChildProject` consumes only that narrow authority. A sibling config or
  descriptive context alone cannot recreate authority, and a child never receives root/harness-root or
  signing authority. Every edge, including teardown, receives a fresh token.
- Replace independently supplied `psChain`, `psFrameContext`, and `psTeardown` interpretations with one
  typed lifecycle plan that derives topology, forward execution, and reverse teardown from the same
  structure, including the child config projection/handoff action, so a no-op `context-init` label cannot
  disagree with independently delivered config.
- Before the first effect, atomically persist/fsync a protected, versioned, non-secret
  `StablePlanSnapshot` containing canonical frame/resource graph, operation keys, cleanup adapter
  parameters/policies, and plan/config/code/schema/interpreter digests. Every one-use command/handoff
  invocation atomically opens one versioned operation session, advances the shared Open project-journal
  version, and returns the sole successor state/permit pair; session close does the same. Registering an
  operation's initial intent consumes the exact no-prior-generation or released-reacquisition origin,
  atomically adds that generation to the exact session, and advances both versions, so no orphan intent
  can be omitted from recovery and the caller cannot choose a generation. Every child effect uses one protected
  prepare compare-and-swap that revalidates the project-mode and broker/authority epochs, bound lease,
  active revision/no migration freeze, exact verb/phase/frame/Open-project/session/current fence,
  journal version/phase, operation key, exact plan-owned closed zero/one/many precondition set, and call
  digest; it reruns all target/dependency probes and conditional versions before recording the exact
  unknown state. It jointly returns matching attempt-indexed `PreparedOperation` and fresh
  `PreparedPreconditions` plus the fresh-versioned
  successor Open-session, Open-project operation state, and revision-permit authority; the consumed
  journal version cannot authorize another prepare or close. The prepared pair retains the exact
  target/generation/operation/precondition-set/call-digest/session/fence/attempt/journal indices and must match the plan descriptor,
  operation binding, or teardown step. Every terminal observation returns `OperationAdvance` on success
  or typed failure; its eliminator yields the result only with the sole successor Open-project
  state/revision-permit pair. Only that prepared pair can enter the adapter; retained `Ready`/
  prerequisite values and either half cannot. Initial fence creation
  and crash-time
  `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved` rotation are durable and idempotently
  resume one proposed epoch; delayed old permits are rejected or deduplicated. Terminal acknowledgment
  verifies all outcomes settled and CASes the exact session version Closed, so it cannot race prepare.
  After successful recursive Production `up`/`down`, mint the opaque
  `ProductionInvocationCompleted` only from the independently complete Closed-session/terminal-operation
  sets with no live prepared operation and atomically revoke broker admission. The Phase 10 close transition must
  consume that exact terminal version and close only the bound lease/broker invocation. Its closed branch
  retains Production mode, bound snapshot/binding, active revision/journal/resource records, complete
  rehydrated resources, and `OpenProject`; it returns no bound lease, admission, or revision-permit authority.
  Its unknown branch returns only the stable close identity. A stale-open recovery branch can only
  reprobe/resume that same close key, never reopen a command. `destroy` and a true pre-effect refusal
  continue through `releaseProductionMode`, not this retaining close.
  Clean active-revision admission is available only after proving that no older broker session remains
  Open. Abandoned-run activation instead uses the exact old-permit fence set to CAS-rebind each existing
  stable session record once, verifies the manifest pairing the independent complete session set with
  its independently complete operation set, and totally classifies unknown, the five pre-call
  continuable phases, already-observed retryable, successful, and terminal records through a protected
  exact-set interpreter. Only continuable phases get current-fence prepare authority; only
  reservation/effect/adoption absence, same-identity ordinary/adopted teardown, repair-original, and
  phase-from get current-fence same-key retry authority. It includes zero-operation Open sessions,
  verifies/rebinds the complete resource-record set,
  and yields current-broker admission plus fresh resource evidence only after every recovered session is
  Closed and every operation is settled. Missing/duplicate members, wrong membership,
  missing/foreign/replaced resource evidence, or unresolved internal recovery cannot open a new command
  session. A persisted initial intent without a fence is an explicit continuable state but cannot
  prepare; the recovery classifier idempotently completes the stable initial-fence protocol and threads
  the sole successor session/state/permit before exposing its current fence.
- Interpret Phase 9.10's durable acquisition journal across recursion. A child crash while acquiring an
  authoritative reservation remains `ReservationOutcomeUnknown`; a crash after a mutating effect but
  before receipt commit remains `EffectOutcomeUnknown`. Restart reprobes the same generation before
  retrying or adopting any result. Teardown reprobes `TeardownOutcomeUnknown` entries and never repeats
  `Released` work, so partial failure cannot be represented as “start the whole cleanup again.”
  Adoption records `AdoptionOutcomeUnknown` before transfer and
  `AdoptionTeardownOutcomeUnknown` before adopted release; neither borrows the ordinary acquisition
  graph.
  Interpret the separate repair and managed phase-effect journals too: repair, boot, stop, and
  destroy-reachability record intent/unknown before their calls, then total-reprobe the exact
  original/from, target/to, absent, unexpected-third-phase, or foreign observation under the exact
  operation key while preserving the original receipt. Only target/to can commit; original/from can
  retry only under the same key after `OldPermitsFenced`; absent, unexpected, and foreign branches are
  terminal/operator-resolution outcomes with no commit edge.
- Derive distinct reverse projections for `down` and `destroy`: `down` may delete the ephemeral Kind
  cluster because Kind has no stop operation, but it never deletes a durable host root or provider
  frame/disk; `destroy` additionally deletes acquired provider frames/disks. The host-root `.data`
  remains **inside** the one plan with an explicit `Preserve` policy and verified receipt, so neither
  verb-indexed projection can delete it. Interpret each projection through an opaque verb/frame/child-set
  teardown forest. `openTeardownForest` is its sole initial producer and binds the pure reverse plan to
  the exact snapshot/active revision/Open-state/permit version. Its exhaustive next-work eliminator
  yields `CompletedTeardownForest` or a closed `TeardownAuthorizationPoint`; only its private eliminator
  exposes the plan-derived destroy-only pre-descent reachability step or ordinary settled-child/cursor
  pair. Callers cannot wrap either branch. After `down`, that pre-descent step can make a stopped provider
  teardown-reachable before retained children are visited; only its successor forest exposes those
  children, and only their later settlement exposes the ordinary provider stop/delete step. Every
  attempt returns an updated forest even on failure, unrelated siblings remain schedulable, and failed
  descendants keep their parent blocked. Only a completed Destroy forest can enter
  `verifyDestroySettled`.
  Recovered ordinary-step resource evidence is a closed owned-or-released sum made only from the bound
  snapshot, plan binding, complete rehydrated set, and exact forest step. The owned branch yields its
  managed handle/receipt; the released branch yields only its verified ordinary/adopted tombstone and
  bindings, receives no backend-call authority, and can mint `FreshGeneration` only after the protected
  absence verifier binds it to a distinct new acquisition key. That token is only eligibility: its sole
  consumer creates the exact reacquisition origin, which registration must revalidate/consume atomically
  with the new-generation intent and session membership.
- Derive a third, harness-only terminal-close projection from the same graph/journal. Both ordinary
  project verbs preserve the durable root. The sole `verifyDestroySettled` producer checks the complete
  child-first destroy forest, terminal release observations, protected journal, and lack of unresolved
  nodes/live prepared operations, plus the independently complete Closed session set. The sole
  `verifyNoProjectResourcesAcquired` producer checks that the exact bound
  tuple contains no resource operation/prepare/fence/receipt/effect record and every registered session
  is Closed and empty. Only their closed conversions mint the two branches of
  `ProjectClosureEvidence`; unresolved partial ownership mints neither. Only that proof plus the
  project-wide Harness mode lease, bound snapshot/lease, same-version Open state, and narrow
  `HarnessCloseRoot`—derived from the live harness root or exact abandoned-run recovery authority—can
  enter the close gate. It verifies every ordinary session Closed and atomically CASes Open→a fresh
  Closing epoch while creating its close journal. The close projection releases the run-owned generated
  config and `.test_data/<runId>` generations through close-specific durable
  unknown/reprobe/fence permits. A persisted Closing epoch resumes only that authority/journal; it cannot
  become Open. Every terminal close observation returns `HarnessCloseAdvance` on success or typed
  failure; its eliminator yields the sole successor close journal. After all close outcomes/sessions
  settle, one finalizer atomically records `ClosedProject`, closes the bound lease, and releases Harness
  mode last. It has no Production constructor and is restartable after every kill.
- Give Production its own closed `ProductionClosureAuthorization`: settled closure requires the exact
  `ProjectDestroy` root plus `DestroySettled`, while any exact Production verb may close only with
  `VerifiedNoProjectResourcesAcquired`. The finalizer revalidates that authorization with the exact
  mode/lease/snapshot/Open state and complete Closed-session set in one compare-and-swap that records
  `ClosedProject`, closes the invocation lease, and clears mode. Session opening compare-and-swaps that
  same project-journal version, so it and finalization have one winner; a pre-effect `up` refusal closes
  cleanly, partial `up`/`down` teardown cannot be relabeled as settled destroy, and no mode-cleared partial
  state exists.
- Keep the root broker live for one recursive invocation. A later Production `down`/`destroy` must
  re-run the independent OS/project root gate, verify/bind the stored plan snapshot plus journal/receipts
  and backend identities, open a new broker generation, and bind that generation's exclusive lease to
  the same plan digest before any teardown authority exists. It must work when the sibling config is
  unchanged, edited, or missing and must not infer old topology from a changed binary. Unknown snapshot
  versions/digests refuse without effects. Binding an existing/abandoned invocation yields
  `BoundInvocationRecovery`, not a journal. Production first chooses Open operational revision recovery
  or an exact completed `up`/`down` invocation whose close is stale/unknown; the latter can only finish
  the idempotent bound-lease close while retaining Production mode and project state. Harness chooses
  Open revision recovery or its exact persisted Closing epoch. The Open branch then exhaustively chooses
  normal active, incomplete old-active migration, or completed new-active migration; only its matching
  activation gate exposes the complete rehydrated resource set, journal/permit authority, and
  current-broker session admission.
  A normal configful abandoned Production `ProjectUp` must open the exact bound-recovery profile and use
  `withRecoveredProductionProjectPlan` to reproduce only the bound plan/digest. Incomplete configful
  recovery uses `withRecoveredMigrationPlanSnapshot`; completed post-CAS configful recovery requires the
  exact new-bound profile at `withCompletedMigrationPlan`. Harness/configless teardown receives none of
  those profile-bearing gates.

  Compatible revision carry begins when the sole `withProjectUpMigrationProfile` producer revalidates
  the exact `ProjectUp` migration root, active mode, old-bound lease/snapshot/binding, and normal-active
  recovery without requiring a new plan. `withProspectiveMigrationPlan` consumes that indexed profile
  and same old-bound package with the new validated config and non-empty drafts and constructs one fresh
  candidate plan plus a pure non-authorizing
  `ProspectivePlanSnapshot`/binding inside a rank-2 continuation. `withPlanMigration` accepts only that
  exact package, persists/fsyncs and authoritatively reads it back under a fresh
  `stableMigrationKey`, and does not freeze when persistence fails or remains unknown. A crash in that
  pre-freeze window leaves only a non-authorizing unreferenced prospective record. After persistence,
  the gate derives the complete exact `VerifiedResourceRecordSet` internally, freezes old operation
  preparation while atomically recording the stable key and revoking session admission, and drains or
  authoritatively fences every prior permit before staging. Session opening and freeze contend on the
  same project-journal/revision version: freeze cannot settle until every independently enumerated
  session, including a zero-operation session, is Closed, while a retained admission cannot open
  afterward. Each
  `PlanMigrationAuthority` is indexed by unchanged frame/resource/generation/ownership-operation/key/
  policy, settled owned-or-released disposition, complete `recordSetDigest`, and frozen revision. A
  plan-owned exact-set fold rejects missing, duplicate, extra, unknown, or disposition-mismatched bundles;
  owned bundles carry receipts, while released bundles carry only tombstones and cannot become managed.
  Live migration uses `bindLiveMigrationPlanSnapshot` over the already-built candidate and exact
  stable-keyed persisted proof; it cannot reconstruct or substitute a plan after freeze. Abandoned
  Production `ProjectUp` first loads the exact persisted prospective `VerifiedPlanSnapshot` named by
  the incomplete record, then uses Phase 10's exact bound-recovery profile opener and
  `withRecoveredMigrationPlanSnapshot`; config/drafts may reconstruct only when they render that loaded
  snapshot. Prospective, frozen, reconstructed, and staged values authorize no effects. Freeze replaces
  the old bound lease with one stable-keyed `FrozenMigrationRunLease`. One protected compare-and-swap
  consumes that capability, archives old active records, changes the lineage old→new, returns only the
  new-digest lease, and yields the exact
  `PlanMigrationBarrier`. `activateMigratedPlan` must consume it with the active revision, bound
  plan/binding, and complete set, recheck that no old session remains Open, and jointly yield the new
  revision's `CurrentBrokerSessionAdmission` before any new session or prepared operation.

  A pre-CAS kill resumes the frozen incomplete migration under a fresh local `migrationId`; a
  `ProjectDown`/`ProjectDestroy` may instead cancel inactive staging while old remains active. A post-CAS
  kill selects completed recovery. Both configful and configless paths first load the exact prospective
  snapshot named by the durable stable key before constructing or binding any local plan; current config
  cannot infer a replacement target. Configful `up` rebuilds and activates only a plan matching those
  persisted bytes, while configless teardown derives its non-secret recovery plan from the same protected
  snapshot. Kill between CAS and activation cannot issue a `PreparedOperation`. Old binding/preparation cannot reopen
  after the CAS.
  At each recovered child boundary the snapshot derives a signed non-secret
  adapter wire; the gate requires the exact parent→child `RecoveryProjectionBinding`,
  `VerifiedRecoveryWire`, `VerifiedHandoff ... RecoveryHandoff ... TeardownPhase`, bound lease, recovered
  frame, and closed forest-produced `TeardownAuthorizationPoint` containing either the ordinary
  settled-child/cursor pair or exact destroy-only pre-descent step. The recovered frame and matching
  closed owned/released evidence can be produced only from the bound snapshot plus complete rehydrated
  resource set and that exact point/step: owned yields the managed handle/receipt/resource/operation
  bindings; released yields only its verified tombstone/bindings. It does not need the old normal config and
  cannot authorize `ProjectUp`. Lost acknowledgments recover from already-durable operation records.
- Continue independent cleanup after an error and report all failures structurally; a `SafetyRefusal` or
  `Conflict` skips only foreign resources, not the run's other owned state.
- Cover provider VM, container, cluster, generated config, durable share, global WSL setting, and host
  daemon ownership in one teardown plan.

#### Validation

- Failure injection at every transition proves no owned descendant leaks and no unacquired/foreign
  descendant is touched.
- Structural/property tests prove the rendered topology, forward traversal, and reverse teardown are
  projections of one plan and contain the same resource identities. Compile-fail tests prove another
  Production plan's journal cannot enter this plan and `TeardownPlan ... Down` cannot be used as
  `TeardownPlan ... Destroy`. No cursor/forest exists before `openTeardownForest` binds the exact
  snapshot/state/permit tuple; its terminal branch is the only source of `CompletedTeardownForest`. A
  work authorization point cannot be constructed outside the forest, and a parent teardown step cannot
  be exposed until its exact verb-indexed child set is settled; a failed node retains its forest
  continuation while independent siblings run.
- Compile-time negative fixtures prove a `Production` plan/handle/receipt cannot mix with a
  `Harness projectId runId` value (or with a different project/harness run), and cross-process tests prove a matching root
  broker challenge/grant succeeds once while wrong-plan/scope/edge/config identity, stale broker
  generation, envelope-supplied verification key, replayed/recorded transcripts, and bring-up-token reuse
  during teardown fail. Broker loss before prepare refuses; loss after a prepared backend call leaves an explicit unknown.
  Nested recursion proves a child requests its next grant through the root relay. Session/fence
  kill/race tests cover one-use open, initial fence, every rotation phase, prepare, success/failure
  `OperationAdvance`, settle, close, delayed old permits, and prove prepare versus session/project close
  has exactly one winner. Compile/runtime fixtures reject retained `Ready`, either prepared half, a
  wrong edge/precondition-set/call digest/version, or a prepared pair paired with another
  target/operation binding or teardown step and prove the result cannot be observed without the sole
  successor state/permit pair. Kill after each continuable pre-call phase and each retryable observed
  phase proves recovery can re-enter only its matching current-fence or fenced same-key prepare;
  terminal/success branches receive no effect authority. An initial intent and its session membership
  cannot be torn apart by a kill. After a kill immediately afterward but before the first fence record,
  recovery starts and persists the sole epoch; only an interruption after that record resumes it. No path
  reaches prepare without the real current fence.
- Idempotence/process-kill tests cover every acquisition-journal boundary, repeated down/destroy, and
  partial prior cleanup: uncertain effects are reprobed under the same generation, released work is
  skipped, and error reports retain every failed action. Sequence tests exercise `down → up`,
  `down → destroy`, and `destroy → up`: durable providers restart through the typed `Stopped` path,
  `down → destroy` first uses only the narrow forest-derived
  `TeardownDescentStep ... ProjectDestroy ... Provider Stopped → TeardownReachable`, then reaches the
  ordinary provider stop/delete step only after retained children settle; ephemeral recreation requires
  verified `Released`/`AdoptionReleased` plus the exact-resource `FreshGeneration` rollover, its sole
  origin consumer, and atomic registration. First acquisition requires no-history evidence; stale/
  reused/wrong-resource rollover evidence loses the compare-and-swap. Kill injection on both sides of
  rollover cannot duplicate an uncertain generation.
- Kill injection before/after repair, boot, stop, and `resumeForDestroy` covers original/from,
  target/to, absent, unexpected-third-phase, and foreign observations. It proves only target/to commits,
  only fenced same-key original/from retries, and no other branch can blind-replay, release, or remint
  ownership.
- Harness terminal-close tests prove destroy→up within one variant retains data, then the same plan's
  close projection removes only that run's exact generated config/data root. A true pre-effect refusal
  closes only through the sole no-resource-acquisition verifier; a settled destroy closes only through
  the sole complete-forest verifier. Incomplete/failed forests, live prepared operations, resource/effect-shaped
  records, Open/non-empty sessions, and unresolved partial ownership cannot close; a Closed empty session
  remains eligible. Kill/restart covers Open→Closing, every close-journal
  transition/effect, success/failure `HarnessCloseAdvance`, settlement, `ClosedProject`, lease close, and
  mode release; it reopens the old run's exact persisted Closing epoch with only close authority before a
  new variant and never remints Open. A protected empty-set sweep proof is consumed atomically by fresh
  allocation; Production and a different run fail to construct the authority.
- Production closure fixtures prove `ProjectDestroy` is required for the settled-destroy constructor,
  while an `up`/`down` invocation can release mode only through the exact true-no-effect constructor;
  partial teardown cannot inhabit either. A session-open/finalizer race has exactly one winner, and
  kill/restart around finalization observes either the complete Open tuple or the complete atomic
  `ClosedProject`/closed-lease/released-mode tuple.
- Successful Production `up`/`down` invocation-close fixtures prove the completed-invocation witness
  cannot be minted with an Open/missing/duplicate session, nonterminal operation, or live prepared operation. Race
  stale session admission against the close CAS and inject kills before commit, after commit, and before
  acknowledgment. Recovery must resume/observe the same close key, return no bound lease or effect
  authority, and preserve Production mode, Open project state, active snapshot/revision, and every
  owned/released resource record. The retaining close cannot call the mode-release finalizer.
- Delayed Production teardown tests exit the original `up` process, then cover unchanged/edited/missing
  sibling config and changed installed binary. A fresh root invocation binds the protected snapshot and
  completes teardown; unknown/incompatible snapshot versions refuse, while a validated compatible
  config-only revision receives per-resource migration proof and actually rehydrates the unchanged
  resource under the new local plan. Frame/policy/generation/operation/key/disposition drift and a
  topology-changing revision do not. Missing/foreign/replaced resource records cannot produce a recovered
  frame, handle, receipt, or exact operation binding for forest work. Compile fixtures prove the sole
  migration-profile producer requires the exact old-bound lease/snapshot/binding and active
  `ProjectUp` root/mode; candidate substitution, a fresh/unbound profile, or an attempt to retain both
  old- and new-bound leases cannot type-check or loses the protected compare-and-swap. Kill injection
  before/during prospective snapshot persistence proves freeze cannot precede fsync/read-back and that
  an orphan prospective record has no authority. Kill injection then covers the
  old-prepare/freeze race, every exact-set member, final CAS, and activation. Missing/duplicate/extra
  bundles refuse, a released tombstone stays released, pre-CAS restart creates a fresh local session for
  the same protected migration key and loads its exact persisted prospective snapshot before
  reconstructing a plan, and teardown can cancel inactive staging. Post-CAS configful forward
  activation and configless teardown recovery both produce current-broker session admission, while no
  new-revision session/prepared-operation authority exists before activation and the old digest cannot reopen or prepare
  afterward. The freeze/session-open race has one winner; a zero-operation session prevents
  `OldRevisionSettled` until it closes.
  A nested two-child missing-config case proves every boundary uses only its signed recovery payload and
  snapshot-derived adapter binding.
- Native provider lifecycle runs interrupt bring-up at bounded checkpoints and verify complete owned
  cleanup/restoration.

#### Remaining Work

Blocked until Sprints 5.7, 9.10, 10.9, 15.9, and 19.7–19.8 land the ownership/result algebra, profile
opener, independent root/command authority, scoped codec, and finalized plan. Then replace best-effort
root-only reconstruction with the scope-retaining typed
acquisition journal, authenticated one-time handoff consumption, and recursive unwind; integrate the
ownership conflict semantics and complete interruption gates. Sprint 16.5 remains Active only for native
accelerator lifecycle validation.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` - canonical home of the model: the current chain
  `[Step]` forward ordering, `project up` as its recursive/fractal interpreter, the target opaque
  forward/topology/reverse plan, and the Python bootstrapper as the metal-frame instance of the fractal
  bootstrap.
- `documents/architecture/hostbootstrap_core_library.md` - the surfaced core command tree
  (`project init|up|down|destroy`, `context`, `test init|run`, `check-code`) and the `Step` algebra a
  project extends with its chain.
- `documents/architecture/library_hierarchy.md` - extension-stream stream 1 is the lift chain (`[Step]`, core +
  project step kinds).
- `documents/architecture/binary_context_config.md` - current child projection/delivery is independent of
  the announcing `context-init` row; the target plan unifies them, `context` is read-only, and `.dhall` is
  parameters + context + witness with per-frame fail-fast on the handoff.
- `documents/architecture/durable_state.md` - canonical home of what the never-delete-`.data` invariant
  and the implemented host-root carry guarantee for `project down` / `project destroy`: `down` may delete
  ephemeral Kind because Kind has no stop operation but deletes neither durable roots nor provider
  frames/disks; `destroy` may delete owned provider frames/disks while host-root `.data` stays outside
  them. Phase 5 Sprint 5.6 owns the sole open live destroy → up → read-back proof.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` - the chain/`Step` pattern plus the recursive interpreter
  as the canonical cookbook.
- `documents/engineering/cluster_lifecycle.md` - cluster bring-up/teardown as chain steps under
  `project up` / `project down` / `project destroy`, adding stop-without-delete.
- `documents/engineering/incus.md`, `documents/engineering/lima.md` - VM lifecycle expressed as core chain
  steps (deploy-VM / down / destroy), including stop-without-delete.
- `documents/engineering/authoring_project_binaries.md` - a consumer authors its
  `chain :: cfg -> [Step]` (plus step actions, test suite, artifacts, Dhall vocabulary), not noun
  verbs.
- `documents/engineering/dhall_topology.md` - topology frames drive the recursive chain; the pb verifies
  its frame.
- `documents/operations/demo_runbook.md` - the demo lifecycle is `project up` / `project down` /
  `project destroy` plus `test run all`, with `context` to visualize the chain.
- `documents/engineering/accelerator_daemon.md` - daemon startup ordering and teardown expectations.

**Cross-references to add:**
- `README.md`, `documents/README.md`, `DEVELOPMENT_PLAN/README.md`, `00-overview.md`,
  `system-components.md`, and `development_plan_standards.md` (§ Y) name Phase 16 and link to the project
  lifecycle command and step-chain interpreter.
- align phase-15 ([phase-15-binary-context-config.md](phase-15-binary-context-config.md)) — which reopens
  the binary-context contract this phase rests on — and phase-17
  ([phase-17-chain-driven-test-and-context-introspection.md](phase-17-chain-driven-test-and-context-introspection.md)),
  which builds the decoupled test surface and read-only `context` introspection on top of this phase.
- record the dissolved `cluster` / `config init` / `context create` / demo verbs in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
