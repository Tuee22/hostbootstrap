# Phase 16: Project lifecycle command

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [00-overview.md](00-overview.md), [README.md](README.md)

> **Purpose**: Build the `Step` algebra, recursive/fractal chain interpreter, and
> `project init|up|down|destroy` lifecycle command, then replace the remaining independent
> lifecycle views with one opaque lifecycle plan (§ W, § Y).

## Phase Status

**Status**: Active

**Sprint 16.6 is unblocked and started 2026-07-30.** Its verb-indexed reverse projection and teardown
forest (`HostBootstrap.Teardown`) landed, which also gave Sprint 10.9's `verifyDestroySettled` its first
producer. It is now the current co-active producer root for the remaining repair tranche: Sprints 10.9
and 15.9 retain their harness/authority contract ownership while this sprint supplies their production
interpreter, handoff, reconciliation, and recursive-teardown consumers. Sprints 11.10 and 14.6, plus
Sprint 10.9's reconciler-produced report rows, wait directly on its still-open items; Sprint 17.4 remains
blocked by 10.9/15.9 and therefore waits transitively. The producer work is listed in the sprint's
`Remaining Work`.

The target is one typed lifecycle plan. Two of the three formerly independent contributions are now
nodes of the validated plan: forward execution always was, and **the per-frame descent joined it
2026-07-30** — a step declares with `descendsVia` how its frame reaches the next one, so topology can no
longer disagree with the forward traversal, and the announced child config and the payload that crosses
the boundary are one value. **The reverse contribution joined it the same day**: an acquiring step
declares the effect that releases it with `reversedBy`, and `project down`/`project destroy` are two
verb-indexed projections of that one plan rather than a hook beside it. All three formerly independent
lifecycle views are therefore nodes of the same validated value. What the single-representation claim
still lacks is the **recursive child-first unwind**: each verb cleans the frames the current binary can
reach rather than descending into every frame it acquired, so the landed teardown forest — whose
child-first ordering and destroy-only pre-descent step only become truthful with that recursion — has
no production call site yet. Sprint 16.6 owns it, along with receipt-driven teardown.

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
and carries it through the provider share/alias and nested mounts, outside the provider disk. The later
destroy → up → read-back proof closed with the evidence recorded in Phase 5 Sprint 5.6. The `Step` algebra (16.1), the
recursive interpreter + multi-frame descent (16.2), the `project init|up|down|destroy` command (16.3),
and the demo chain migration incl. dissolving the
old `deploy` / `harbor` / `role` verbs + the Op-based `HostBootstrapDemo.Chain` (16.4) all landed. The core
tree carries only `coreCommandNames` = `context` / `project` / `test` / `service` / `check-code`; `ensure`
is a reconciler library composed through `ensure-*` steps, not a verb. The flat `cluster`, `config init`,
`config show|schema|render`, and `context create` verbs are removed; the demo contributes
`demoChainFor`, with its old per-project
Harbor names retained here only as historical run evidence and its removed verbs recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The current demo uses registry/MinIO
steps; Phase 13.18/21.4 remove stale Harbor metadata. Sprint 16.6 reopens lifecycle closure for
receipt-driven recursive teardown.

Forward-pointer: under the generic project model, `project init` sources its defaults from the
project-supplied `psAssemble (ProductionAssembly args)` (core owns no default config values). That
parameterization is owned by
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
local-only NodePort and run the implemented browser Add assertion. The dated Windows GPU/WSL2 `8/8` and
the later native Linux GPU/CPU `10/10` runs close those accelerator lanes; they do not exercise Phase
16.6's later typed recursive teardown. Only the Apple host-daemon lane remains open in Sprint 16.5.

**Native Linux CPU lane closed 2026-07-29.** `hostbootstrap-demo test run all` reported **`10/10 passed`**
on a genuinely `linux-cpu`-detecting host (a fresh Ubuntu 24.04 Incus VM, whose kernel carries no NVIDIA
markers and no `nvidia-smi`, with the demo's own Incus VM nested inside it). The run brought up the
VM-backed stack through `cluster up: nodes Ready`, MinIO, the in-cluster registry, `push-image`,
`expose-port: web service reachable at http://localhost:30080/`, and
`deploy-accelerator-daemon: in-cluster accelerator daemon deployed (dials the web ClusterIP ingress)`,
with all five cases (`pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`,
`durable-readback`) passing on both config variants. The complete evidence block lives with the sprint
that owns the lane, [phase-5 Sprint 5.5](phase-5-cluster-lifecycle-and-resource-cordoning.md). This closes
**only** the Linux CPU lane; the Apple Silicon lane has no available host.


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
  `HostBootstrap.CLI`; a project extends core only through checked builder streams (additive plan,
  Dhall vocabulary, schema-gen, test suite, typed services, and frame-context/teardown
  single-assignment). `runHostBootstrapCLI` no longer merges project command mods.
- The residual demo `vm` / `incus` / `web` project verbs are **deleted** (`demoCommands` is gone); their IO
  is retained as the chain-step library functions `runVmEnsure` / `runVmUp` / `runVmBootstrap` /
  the later core-owned Incus provider transition, and the `web` 'ServiceHandler' / build-image bridge codegen
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

Interpret the then-current pure step sequence recursively across the composed frame stack, so
each binary owns its own segment and the command can be invoked at any declared frame (§ U, § Y).
Convergence after a partial failure remains best-effort until Sprint 16.6 lands the durable
identity-bound journal and recovery model. Sprint 19.8 later wrapped this sequence in opaque validated
`StepPlan` without reopening this interpreter sprint.

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
  transport and Phase 5 Sprint 5.6's live destroy → up → read-back proof are implemented and closed —
  see [durable_state](../documents/architecture/durable_state.md).
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
(`HostBootstrap.Command.projectCommandGroup`), with the validated `StepPlan` and checked
frame-context/teardown contributions retained by opaque `ProjectSpec`.
`project up --dry-run` renders that exact plan through the context gate; the apply path
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
`demoChainFor :: Substrate -> ProjectConfig scope -> [Step]`
(`demo/src/HostBootstrapDemo/Commands.hs`) through `addSteps`, with context/teardown assigned once before
`finalizeProjectSpec` in `demo/app/Main.hs`; a real `hostbootstrap-demo project
up` on Incus/Linux ran the chain's three metal-frame steps end-to-end — ensure the VM provider → launch the
budget VM (cordon #1) → pristine-bootstrap (build #2 host-native + build #3 project image in the VM) —
exiting 0, with `project down` / `project destroy` stopping / deleting the VM (the cluster teardown's removal
set never names the data path, § Y). That historical run predates the now-implemented host-root
share/alias carry and therefore is not the still-open destroy → up → read-back proof.
`project up --dry-run` renders the chain and `context inspect` renders the composition. The user chose
(2026-06-17) the maximalist target: `project up` ends at a **persistent full stack**, descending **three
frames** (`host-orchestrator-0` → `vm-orchestrator-1` → `vm-project-container-2`, each a real handoff). The
container-frame migration is landing in code-check-validated increments:

- **Historical Increment 1 (Done, code-check-gated):** the then-current demo chain rendered the full
  3-frame interleaved value —
  metal (`deploy-vm` ×2, `build-pb`) → `vm-orchestrator-1` (`context-init`) → `vm-project-container-2`
  (`deploy-kind`, `deploy-harbor`, `push-image`, `deploy-chart`, `deploy-role`, `expose-port`). The per-frame
  lift-context resolver `demoFrameContext` was wired through the then-current context setter
  (metal→VM folds to `incus exec`,
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

Open only for real-run closure (§ C).

**Native Linux GPU real-run closure (2026-07-28).** The direct-`nvkind` lane reported **`10/10 passed`**
across both variants; the full evidence, including the `nvcc` discovery defect it exposed and fixed, is
recorded once with
[Sprint 5.5](phase-5-cluster-lifecycle-and-resource-cordoning.md). This closes only that lane.

That run executed the native Linux **GPU** in-cluster deployment and the implemented browser Add
assertion across the full five-case/two-variant harness. The accepted Windows GPU/WSL2 `8/8` closes its
host-daemon lane. The later native Linux **CPU** `10/10` run closes the CPU deployment; only the Apple
host-daemon lifecycle through the local-only NodePort remains. Those runs do not close Sprint 16.6's
typed plan/journal teardown contract, which they predate.

### Sprint 16.6: Ownership-preserving recursive teardown [Active]

**Status**: Active

**Unblocked and started 2026-07-30.** Closed Sprints 5.7, 9.10, and 19.7–19.8 and the required producer
foundations from active Sprints 10.9 and 15.9 have landed. Sprints 10.9, 15.9, and 16.6 are now one
co-active integration tranche: 10.9 owns the harness authority/close/report contracts, 15.9 owns the
opaque authority/handoff/prepare contracts, and 16.6 supplies their production interpreter, handoff,
reconciliation, and recursive-teardown producers. The first deliverable, the verb-indexed reverse
projection and its teardown forest, landed 2026-07-30; the rest is listed under `Remaining Work`.
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`,
`core/hostbootstrap-core/test/PrepareFixture.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeTeardownForest.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgePreparedGate.hs`,
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
- Replace independently supplied chain, frame-context, and teardown interpretations with one
  typed lifecycle plan that derives topology, forward execution, and reverse teardown from the same
  structure, including the child config projection/handoff action, so a no-op `context-init` label cannot
  disagree with independently delivered config.
- Carry the plan-bound canonical root identity through recursive interpretation and render only the
  adapter-owned typed projection at each boundary. No child frame reconstructs a host root from
  `sourceRoot`, `cwd`, a guest alias, or a serialized absolute path.
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

**Delivered 2026-07-30 — the verb-indexed reverse projection and the teardown forest
(`HostBootstrap.Teardown`).**

This is the deliverable that begins "Derive distinct reverse projections for `down` and `destroy`", and
it is also the one Sprint 10.9 has been waiting on: `verifyDestroySettled` had no producer, so the
`SettledDestroyClose` branch of `ProjectClosureEvidence` was uninhabited and a Production project could
be closed after a true pre-effect refusal but never after an actual `destroy`.

- **The two projections are one plan, structurally.** `teardownPlan` takes only a `LifecyclePlan` and a
  verb; it reads the validated `StepPlan` out of the plan itself through the new
  `Reconcile.lifecyclePlanSteps` rather than accepting one from the caller, so the forward traversal and
  the reverse teardown cannot name different resources. A test asserts both verbs project the **same**
  identities and that they are exactly the forward plan's operation keys.
- **The verbs differ in exactly one place.** A `deploy-vm` step is `StopFrame` under `down` and
  `DeleteFrame` under `destroy`; `deploy-kind` is `DeleteCluster` under **both**, because kind has no
  reliable stop/restart contract. `TeardownPlan scope planId verb` is verb-indexed, so a `Down`
  projection, live forest, or completed proof cannot be substituted for a `Destroy` one — proved by the
  new `ForgeTeardownForest.hs` fixture.
- **`PreserveOnReverse` is honoured by construction.** Such a step never enters either projection, which
  is how the host-root `.data` stays inside the one plan with an explicit preserve policy instead of
  being excluded by a special case at the call site. A plan whose every step preserves projects nothing
  and cannot open a forest at all.
- **`openTeardownForest` is the sole initial producer**, and the forest enforces child-first recursion: a
  frame's own step is not offered until every deeper node has settled. For `destroy`, a provider node
  first offers a **pre-descent reachability** step — after a `down` the provider is stopped and its
  retained children are unreachable — and only that step's success exposes the children, whose
  settlement in turn exposes the ordinary delete. The observed order on the demo's own three-frame shape
  is asserted exactly.
- **The authorization point's private eliminator** exposes either the destroy-only pre-descent step or
  the settled-child proof paired with the ordinary cursor. `SettledChildren`, `PreDescentStep`,
  `TeardownCursor`, `TeardownAuthorizationPoint`, `CompletedTeardownForest`, `TeardownForest`,
  `TeardownProgress`, and `DestroySettled` all hide their constructors, so a caller cannot claim children
  settled when they are not, invent a reachability step for a `down`, or start a forest mid-traversal.
- **Failure is constructive.** Every attempt returns a successor forest, including on failure. A failed
  node keeps its exact parent blocked while unrelated siblings stay schedulable — implemented as two
  scheduling passes, fresh work then retries, because a single depth-first pass re-offers the first
  failure forever and starves its siblings. A permanently failing node therefore keeps the forest from
  ever completing, which is asserted directly.
- **Foreign and refused observations are not failures** (§ Y): both settle their node without touching
  the object and are recorded separately from failures, so a `SafetyRefusal` or `Conflict` skips only
  that resource rather than aborting the run's other owned cleanup.
- **`verifyDestroySettled` accepts only a completed `Destroy` forest** and additionally refuses one that
  settled fewer nodes than the projection names, so a truncated traversal cannot pass as a settled
  destroy. `Lifecycle.Mode.destroySettledClosure` is the new conversion: it takes the `BoundRunLease`,
  `verifyAllSessionsClosed`'s completeness proof, and `DestroySettled`, compares both proofs against the
  lease's own plan digest, and mints `ProjectClosureEvidence SettledDestroyClose`.

**Deviation from the sprint text, recorded deliberately.** The deliverable says `openTeardownForest`
binds "the exact snapshot/active revision/Open-state/permit version". It currently binds the
`LifecyclePlan` only. Those other values live in `HostBootstrap.Lifecycle.Mode`, and `Mode` must import
`Teardown` to supply `destroySettledClosure`; binding them inside `openTeardownForest` would be an import
cycle. The binding is therefore made at the conversion instead — which is where it decides anything —
and moving it into the opener is part of the plan-snapshot work below.

Validation (2026-07-30): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **786** (up from 769). `TeardownSpec` contributes **16**
cases over the demo's own three-frame plan shape; `ForgeTeardownForest.hs` pins ten constructors and
three verb substitutions as unreachable, and `CompileFailSpec` now runs **32** fixtures.

**Delivered 2026-07-30 — the independent root gate on `project up|down|destroy`.**

Before this, the three lifecycle verbs were authorized by nothing more than the decoded context's
command-class membership — self-asserted authority of exactly the kind § X forbids — and
`Authority.withVerifiedRootInvocation` had **no production consumer at all**, which is the concrete
reason nothing could sign a runtime-role activation manifest (Sprint 14.6) and why Sprint 15.9's wiring
list named this first.

- `withRootLifecycleAuthority` in `HostBootstrap.Command` now runs each verb behind
  `verifyOperatorAuthorization` → `withFreshBrokerEpoch` → `withVerifiedRootInvocation` →
  `authorizeProjectCommand`, over the `LifecyclePlan` built from the same admitted config snapshot the
  chain executes. It fails closed. `ProjectUp`, `ProjectDown`, and `ProjectDestroy` each pass their own
  closed `ProjectVerb`, so an `up` grant cannot authorize a `destroy`.
- The broker epoch is fresh per invocation, so the one-use invocation record
  `authorizeProjectCommand` reserves is fresh per invocation and an ordinary re-run is not misread as a
  replay.
- **The gate runs at the root frame only.** A nested frame is reached through the recursive handoff and
  must take its authority from the parent's relay, which item 3 below still owes; gating it from its own
  sibling config would re-assert exactly what is being removed. That restriction is explicit in the code
  and is not silent.
- The store is the project's own `.hostbootstrap/authority/<project>` under the **canonical** root
  (§ X), never the caller's working directory. It is keyed by installed project name as well as root,
  because one project root can legitimately host more than one installed binary — this repository hosts
  both `hostbootstrap` and `hostbootstrap-demo`. `withVerifiedRootInvocation` still refuses a store whose
  recorded project is not this one, so a directory copied under another name is caught. `.gitignore`
  already covers `.hostbootstrap/`.

`CLISpec` grew a case asserting the gate is observable rather than inert: after `project up`, the
project's authority store exists at that exact path. Validation (2026-07-30): `cabal build all` and
`cabal test all --ghc-options=-Werror` pass from `core/` at **787**; the demo workspace passes **110**
plus the embedded **787**. This is static-gated only — it changes the live `project up` path, so the
native demo lane should be re-run before Phase 16 closes.

**Delivered 2026-07-30 — the plan-owned dependency-snapshot traversal (§ CC).**

This is the first half of open item 1, and it removes the exact obstruction Sprint 11.10's dependency
finding recorded: a descriptor's dependency set was the whole preceding step prefix, so any plan whose
prefix contained a step with no plan resource — which is every real project chain, because a project's
own `ensure` fragment precedes the provider — demanded an observation that was **unconstructible**.

- **The edge set is now the exact ordered *resource-bearing* prefix.** `plannedKindKey` is the single
  closed table naming which operation key each planned resource family owns, and both
  `plannedKindAccepts` and the new `plannedResourceFamilyKeys` read it, so a family cannot be admitted to
  one and omitted from the other. `plannedOperation` filters `stepDependencies` through that table. A step
  that owns no plan resource has no managed handle to observe, so including it made the set unsatisfiable
  rather than stricter. `ReconcileSpec` proves that on a demo-shaped plan
  (`project:ensure-vm-provider` → `core:deploy-vm` → `core:copy-source`) the durable share's edge set is
  exactly `["core:deploy-vm"]`, and that the traversal then seals it.
- **The caller no longer supplies observations.** `withPreparedOperation` took a caller-built
  `[SomeDependencyObservation]`; it now takes a sealed `OperationPreconditionSet` whose sole producer is
  `withOperationPreconditions`. That traversal iterates the *descriptor's* edge set — not the snapshot —
  looks each member up in the `DependencySnapshot` of managed resources, and runs that member's
  plan-owned probe **at prepare time**. A member the snapshot does not carry refuses
  (`ReprobeBeforeRetry`, naming the unmanaged key); a member carried twice is a `Conflict` rather than a
  silent first-wins; a probe that does not observe readiness returns its own typed failure. Selecting or
  omitting a member is therefore not expressible.
- **The snapshot cannot hold an unowned resource.** An entry pairs a `Managed` handle — which only
  `completeReconcile` / `completePreparedUnchanged` mint — with a `DependencyProbe`.
  `Readiness.planDependencyProbe` builds that probe from the plan-indexed `Probe`, and rechecks the
  freshly minted `Ready` against the handle's generation and observation version on **every** run, which
  is what `dependencyObservationFromReady` used to do once against a retained value.
- **The zero-dependency branch is explicit and refusing.** `zeroDependencyPreconditions` serves
  descriptors that declare no edges (§ CC's private zero-dependency branch) and refuses any descriptor
  that names one, so it is not a route around the snapshot.
- `ForgePreconditionSet.hs` pins the sealed set and the snapshot constructor as unreachable, and
  `CompileFailSpec` now runs **33** fixtures.

Validation (2026-07-30): `cabal build all --enable-tests --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **794** (up from 787); the demo workspace passes **110** demo
tests plus the embedded **794**-test core suite under the same gate; `poetry run python -m
hostbootstrap.check_code` is clean and `poetry run python -m hostbootstrap.test_all` passes **231**;
`git diff --check` is clean. The seven new cases are the three `ReconcileSpec` edge-set/seal/zero-branch
cases, the three `ClusterReconcileSpec` traversal-refusal cases (unmanaged dependency, duplicate entry,
failing probe), and the new compile-fail fixture.

**Delivered 2026-07-30 — the prepare gate in front of the adapter pair (§ EE).**

This closes the journal-version half of the weakness the traversal above left open. It is the item's
own scoping note carried out: rather than adding a bridge that leaves the raw arguments exported, the
evidence moved to a shared lower module both sides can name.

- **`HostBootstrap.Lifecycle.Prepared` is that module.** It imports only `HostBootstrap.Protected`, so
  it sits below both `Lifecycle.Session` and `Reconcile` and breaks the
  `Session -> Authority -> Reconcile` layering problem without inverting anything.
- **`PreparedGate` hides its constructor and has exactly one producer.** `recordDurableUnknown`
  *performs* the compare-and-swap that publishes the operation's unknown phase and mints the gate from
  the version that write returned, so the value cannot exist unless that durable write landed. It
  requires a `ProtectedSession`, which exists only inside an exclusive protected entry (§ EE clause 1).
  Because it also writes the exact four-field record layout the recovery classifier reads back, the
  bytes on disk and the indices on the gate cannot disagree. `ForgePreparedGate.hs` pins both the
  constructor and a record update as unreachable.
- **`Reconcile.withPreparedOperation` no longer takes an attempt and a journal version.** It takes the
  gate, and reads both off it. `Cluster.Reconcile.withPreparedClusterReconcile` and
  `Provider.Alias.withPreparedGuestAliasCall` — the two adapters — thread it through, so no route to a
  prepared pair accepts a `Word64` any more.
- **The gate is bound to its plan and its operation, and both are checked.** `PlannedResource` and
  `OperationDescriptor` now carry the plan digest they were resolved from, and the prepare refuses a
  gate recorded under a different plan digest or a different operation key. That is deliberately a
  *value* check rather than a phantom index: a phantom parameter on the gate would be freely
  instantiable by whoever holds the value, so it would record the binding without enforcing it. Two new
  `ReconcileSpec` cases prove each refusal.
- **The specs mint the gate the way production does.** There is no test-only constructor to reach for
  (§ EE forbids exporting one), so `PrepareFixture` opens a real protected store in a temporary
  directory and records a real unknown phase inside a real exclusive entry. Every prepared-operation
  spec — `ReconcileSpec`, `ClusterReconcileSpec`, `ProviderAliasSpec` — now runs against that.

Validation (2026-07-30): `cabal build all --enable-tests --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **797** (up from 794); the demo workspace passes **110**
demo tests plus the embedded **797**-test core suite under the same gate. `CompileFailSpec` now runs
**34** fixtures.

**Delivered 2026-07-30 — the plan-owned frame descent, and the root-bound plan (§ W/§ X).**

This is the first half of open item 3. The chain was already one validated forward ordering, but the
**descent** beside it was not: `psFrameContext` was a separately assigned `StepFrame -> LiftContext`
resolver, so the frame the plan announced and the context the interpreter dispatched into were two
independently supplied values. In the demo that gap was visible by name — the `context-init` step's body
was a `putStrLn` announcing a child config it did not carry, while the payload that actually crossed the
boundary was folded in by `demoFrameContext` somewhere else entirely. That is exactly the disagreement
this deliverable names.

- **A step declares its own descent.** `HostBootstrap.Step.descendsVia` attaches the boundary's
  `LiftContext` — provider dispatch *and* the child config streamed on the handoff `stdin` (§ X) — to the
  plan node that owns it. `frameDescent` reads it back, and `Chain.runChainFromFrame` no longer takes a
  resolver argument at all: it looks the context up in the plan it is already interpreting. There is no
  second value to drift.
- **Validation makes the pairing total, not conventional.** `mkStepPlan` requires **exactly one** descent
  per frame that has a successor (`MissingFrameDescent` / `DuplicateFrameDescent`), **none** from the
  innermost frame (`DescentFromInnermostFrame`), and none on a post-handoff hook
  (`DescentOnPostHandoffStep`, which runs *after* the descent). `descendsVia` appends rather than
  replaces, so a second declaration on one step is retained as a construction conflict and rejected too.
  Because the descent is checked at plan construction, `--dry-run` and `project up` are still the same
  value.
- **`setFrameContext` / `psFrameContext` are deleted**, along with `MissingFrameContext` and
  `DuplicateFrameContextAssignments`. There is no remaining API through which a project can supply a
  frame context that the plan does not contain; the removal is recorded in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
- **The plan is built under the canonical root.** `addSteps` fragments are now rank-2 in
  `CanonicalProjectRoot`, so a step derives project-relative paths — and the descent it declares — from
  the one admitted authority rather than from `cwd` or a serialized path (§ X). That is what let the
  demo's Linux GPU descent keep its `CanonicalHostDurable` mount after the resolver was removed; nothing
  reconstructs a host root at the boundary.
- **The demo's two lanes each declare their descents on the honest node.** The VM-backed stack declares
  metal → `vm-orchestrator-1` on its `build-pb` step (the substrate's VM shell) and
  `vm-orchestrator-1` → `vm-project-container-2` on the very `context-init` step whose label announces
  the child config. The direct Linux GPU lane declares its single metal → container descent on its own
  `context-init`. `demoFrameContext` is gone.

Validation (2026-07-30): `cabal build all --enable-tests --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **801** (up from 797); the demo workspace passes **110** demo
tests plus the embedded **801**-test core suite under the same gate; `poetry run python -m
hostbootstrap.check_code` is clean and `poetry run python -m hostbootstrap.test_all` passes **231**;
`git diff --check` is clean. The four new cases are two `ChainSpec` cases proving the dispatched handoff
argv is derived from the plan's own descent node (and that the innermost frame declares none) and two
`StepSpec` cases pinning each of the four new validation refusals. `CommandsSpec`'s
direct-versus-VM-backed handoff case now reads both contexts out of the two demo plans rather than out
of the deleted resolver, so it proves the same `--gpus=all` / durable-mount distinction *and* that the
contexts are plan nodes.

**Delivered 2026-07-30 — the plan-owned reverse effect; `psTeardown` is gone.**

This is the second half of open item 3, and it removes the last lifecycle contribution supplied
independently of the plan. `psTeardown` was one `root -> cfg -> Bool -> IO ()` hook for the **whole
project**: a `Bool` chose stop-or-delete, the demo's implementation re-derived the substrate and
branched on it internally, and nothing tied any of it to the plan node that had acquired the resource.
A step could therefore acquire something the hook never released, or the hook could release something no
step ever acquired, and neither would be visible at construction.

- **The acquiring node declares the releasing effect.** `HostBootstrap.Step.reversedBy` attaches
  `HostConfig -> TeardownAction -> IO TeardownOutcome` to a step. The `Bool` is gone: the verb-indexed
  `TeardownAction` the projection already derived (`StopFrame` for `down`, `DeleteFrame` for `destroy`,
  `DeleteCluster` for both) is what the effect receives, so a node cannot decide for itself which verb
  it is running under.
- **`Command.reverseProjection` is the one driver, and both verbs go through it.**
  `project down` runs `teardownPlan lifecyclePlan downVerb`, `project destroy` runs the `destroyVerb`
  projection of the *same* plan, and a failed `project up` runs the destroy projection as its
  best-effort unwind — so the three cleanup paths are one representation, not three. Nodes run deepest
  frame first and, within a frame, in exact reverse of the forward sequence, which is what puts the
  host-daemon post-handoff hook ahead of the provider frame it ran beside.
- **A `PreserveOnReverse` step still never enters either projection**, which is now the entire mechanism
  of the never-delete-`.data` invariant at the call site: there is no longer a hook that could reach it.
- **Outcomes are per node and structured.** `TeardownReleased` / `TeardownForeignRetained` /
  `TeardownRefused` / `TeardownFailed` are reported per operation key, a throwing effect is captured as
  `TeardownFailed` rather than aborting the traversal, and the command fails only after every
  independent node has had its turn — § Y's rule that a refusal or a failure skips only its own
  resource. The former behaviour aggregated two coarse labels ("cluster down", "project frame
  teardown").
- **The core keeps the kind cluster, and a project may override it.** A `CoreManagedReverse` node that
  declares nothing is handed to the core's cluster adapter, which still runs only from the frame that
  owns `deploy-kind` and now reports the other case as an explicit retained outcome instead of a bare
  `putStrLn`. A node that *does* declare a reverse takes precedence, which is what the demo's direct
  Linux GPU lane needs: its nvkind cluster lives in a frame the metal host has no kube toolchain for,
  and is reached through the project image.
- **The core adapter dispatches on the node's action, not on the frame alone** — a defect found and
  fixed during this sprint's own review. `deploy-chart` and `expose-port` are core-managed as well, but
  they live *inside* the cluster and have no separate backend call; handing every core-managed node to
  the cluster adapter would have run the whole cluster teardown once per node. Only `DeleteCluster`
  reaches it; the others report as released with the cluster that contains them. A `TeardownSpec` case
  asserts the adapter sees exactly `[("core:deploy-kind", DeleteCluster)]` on the demo-shaped plan.
- **The demo's monolithic `demoTeardown` is replaced by three node-local effects** —
  `demoProviderReverse` on `deploy-vm`, `demoDirectClusterReverse` on the direct lane's `deploy-kind`,
  and `demoHostAcceleratorReverse` on the host-daemon post-handoff step. Each is now attached to the
  step that created the thing it removes, and the substrate branch inside the old hook is gone: the
  chain already selected the lane, so only the nodes that lane contains carry reverses.

**Deliberate scope note.** This drives the pure **reverse projection**, not the `TeardownForest`. The
forest's child-first ordering and destroy-only pre-descent reachability step only become *truthful* once
the verb recurses into each descendant frame; driving it from one frame would let a `destroy` mint
`DestroySettled` for deeper nodes it never visited, which is exactly the false proof § Y exists to
prevent. The recursion is the remaining part of item 3 and is recorded as such below.

Validation (2026-07-30): `cabal build all --enable-tests --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **807** (up from 801); the demo workspace passes **110** demo
tests plus the embedded **807**-test core suite; `poetry run python -m hostbootstrap.check_code` is clean
and `poetry run python -m hostbootstrap.test_all` passes **231**; `git diff --check` is clean. The six new
cases are five `TeardownSpec` driver cases
(the declared effects run deepest-frame-first; the verb reaches the effect as `StopFrame` versus
`DeleteFrame`; a node that declared none is skipped rather than reported released, while a core-managed
one reaches the core adapter; the adapter receives each node's own action; and a throwing effect becomes
a captured failure with later nodes still running) and one `StepSpec` case pinning the two new refusals
plus the permitted core-managed override.
`CLISpec`'s former teardown-hook call-count case is now the plan case: `project down` runs the reverse
the acquiring step declared and observes `StopFrame`, then `project destroy` on the same spec observes
`DeleteFrame`.

**Still open (this sprint), grouped by contract; dependencies are stated on each item:**

**Integrated 2026-08-01 with the active Sprint 10.9 tranche:** the live harness loop now acquires a
fresh run per config variant, threads that acquired run identity into the config bracket, and uses
`withAssembledHarnessConfig` rather than the raw assembly runner. Focused `HarnessSpec` validation passes
23/23 with `-Werror`. This establishes the run→config edge that items 1–3 consume; it does not yet bind
the lifecycle profile/snapshot/plan or replace the independently callable authority opener.

1. **The `copy-source` plan node at the demo call site.** The core half above is landed, but the demo's
   adoption is **ordering-blocked behind item 3, not behind item 1** — a discovery of this work. A step
   action is `HostConfig -> IO ()` (`Step.runStep`), so it receives no `LifecyclePlan`; minting the
   `Managed` durable-share handle that `withPreparedGuestAliasCall` requires is therefore impossible
   inside a step until item 3 replaces that result-free signature with the plan-minted descriptor § U
   already specifies. Sprint 11.10's `Blocked by` edge for its demo alias migration stands, and now names
   item 3 rather than item 1.
2. **The internal handoff receiver and duplex root relay** replacing `Lift.ConfigDelivery`'s shell
   writer — which is also what lets the root gate above extend past the root frame — and the build-image
   coordinator channel that makes `check-code` require `BuildInvocationAuthority`.
3. **The recursive child-first unwind**, the remainder of the single `ProjectPlan` representation. All
   three contributions — forward ordering, per-frame descent, and the reverse effect — are now nodes of
   the one validated plan, and both teardown verbs are projections of it. What remains is that each verb
   cleans only the frames the current binary can reach: `project destroy` at the root does not hand
   `project destroy` into the VM and then the container before running its own reverse steps, so the
   deeper frames are released with their parent rather than visited. Until it does, the landed
   `TeardownForest` has no production call site — its child-first ordering and destroy-only pre-descent
   step would otherwise let a one-frame run mint `DestroySettled` for nodes it never touched. The same
   work carries the `Conflict`/`Unsupported` report-card rows and the receipt-carrying
   `ManagedResult Unchanged` / `ForeignResult` half that Sprint 10.9 is waiting on, and it still owes
   § U's replacement of the result-free `HostConfig -> IO ()` step signature with the plan-minted
   descriptor — which is the exact thing Sprint 11.10's demo alias migration is blocked on. It changes
   live teardown ordering on every provider lane, so it is real-run-gated (§ C), not closable by the
   static gate alone.
4. **The migration/recovery gates** (`withProjectUpMigrationProfile` through `activateMigratedPlan`) and
   the native interruption runs.

Sprint 16.5 remains Active only for native accelerator lifecycle validation.

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
  them. Include the closed Phase 5 Sprint 5.6 live destroy → up → read-back evidence.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` - the chain/`Step` pattern plus the recursive interpreter
  as the canonical cookbook.
- `documents/engineering/cluster_lifecycle.md` - cluster bring-up/teardown as chain steps under
  `project up` / `project down` / `project destroy`, adding stop-without-delete.
- `documents/engineering/incus.md`, `documents/engineering/lima.md` - VM lifecycle expressed as core chain
  steps (deploy-VM / down / destroy), including stop-without-delete.
- `documents/engineering/authoring_project_binaries.md` - a consumer authors additive step fragments
  finalized into `StepPlan` (plus actions, test suite, artifacts, Dhall vocabulary), not noun
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
