# Phase 16: Project Lifecycle Command And Step-Chain Interpreter

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [00-overview.md](00-overview.md), [README.md](README.md)

> **Purpose**: Build the `Step` algebra, the recursive/fractal chain interpreter, and the
> `project init|up|down|destroy` lifecycle command so a project's deploy is exactly the pure
> `chain :: cfg -> [Step]` value the core interprets — the single representation of its
> deployment (§ W, § Y).

## Phase Status

**Status**: Done

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

**All four sprints are `Done` and the model is real-run-validated end-to-end on Incus/Linux (2026-06-18):**
a single `project up` drove the full recursive descent — `host-orchestrator-0` (provision VM, build pb #2 +
image #3) → `vm-orchestrator-1` (`incus exec` handoff, mint the child config) → `vm-project-container-2`
(`docker run` handoff: `deploy-kind` → `deploy-harbor` (the full 8-pod production Harbor) → `push-image` (the
20GB image to the in-cluster registry) → `deploy-chart` → `expose-port`) — to a **live persistent stack**
(the webservice serving HTTP 200 on `localhost:30080`), then `project down` / `project destroy` tore it down
with host `.data` preserved (§ O). The `Step` algebra (16.1), the recursive interpreter + multi-frame descent
(16.2), the `project init|up|down|destroy` command (16.3), and the demo chain migration incl. dissolving the
old `deploy` / `harbor` / `role` verbs + the Op-based `HostBootstrapDemo.Chain` (16.4) all landed. The core
tree carries only `coreCommandNames` = `context` / `project` / `test` / `service` / `check-code`; `ensure`
is a reconciler library composed through `ensure-*` steps, not a verb. The flat `cluster`, `config init`,
`config show|schema|render`, and `context create` verbs are removed; the demo contributes
`demoChain :: ProjectConfig -> [Step]` + `demoFrameContext` + `demoTeardown`, with its old per-project
verbs recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

Forward-pointer: under the generic project model, `project init` sources its defaults from the
project-supplied `psInit` (core owns no default config values) and layers optional flag overrides over
them. That parameterization is owned by
[phase-19-generic-project-model.md](phase-19-generic-project-model.md); the `project init|up|down|destroy`
surface this phase shipped is unchanged.

## Remaining Work

Close the command surface to the fixed core set and make `hostbootstrap-core` a **library of composable
tools**, not a CLI topology (development_plan_standards § P, § T).

**Landed in code (2026-06-19), code-check-validated** (`cabal test all` green; `cabal build all
--ghc-options=-Werror` green; fourmolu/hlint clean on the demo; verified on the real binary that
`hostbootstrap-demo --help` lists only `ensure` / `context` / `project` / `test` / `service` /
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
  deploy-kind, deploy-chart, expose-port), and a project contributes its own step kinds (deploy-harbor,
  launch-web, role) into the same `[Step]`. Host and project steps interleave freely.
- Interpret the chain **recursively/fractally**: `project up` runs the current frame's steps, then for the
  next nested frame provisions it, builds/installs the project binary in it, and hands off `pb project up`
  (the fractal bootstrap, § U), so each binary owns its own segment and the deploy is restartable from any
  frame.
- Surface the lifecycle command `project init|up|down|destroy` on the core optparse tree (§ P), with
  `project up --dry-run` rendering the pure `chain cfg` `[Step]` value (the single representation, § W).
- Hold the doctrine that the sibling `<project>.dhall` carries **parameters + context + witness**, never
  the chain shape; each frame verifies it is in the frame its `<project>.dhall` describes, or fails fast
  (§ X); optional structural variation (skip the VM, deploy straight to Docker) is a root-`<project>.dhall`
  flag so the chain stays a pure function of root parameters.
- Add the VM stop-without-delete capability and cluster-frame teardown semantics so `project down` stops
  provider VMs, deletes kind clusters while preserving durable state, and `project destroy` deletes
  everything spun up while preserving durable host `.data`
  (the never-delete-`.data` invariant, § O).

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
- A project-extension seam so a consumer contributes its own step kinds (for the demo: deploy-harbor,
  launch-web, role) into the same `[Step]` without redefining the core kinds, interleaving host and
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
each binary owns its own segment and the deploy is restartable from any frame (§ U, § Y).

#### Deliverables

- A recursive interpreter in `HostBootstrap.Chain` that, for the current frame, runs this frame's steps,
  then for the next nested frame provisions it, builds/installs the project binary in it, and hands off
  `pb project up` — the fractal bootstrap's three beats (provision the frame, build the pb in it, hand off
  `pb project up`), of which the Python bootstrapper is the metal-frame instance (§ M, § U).
- A per-frame fail-fast guard on the handoff: before a frame acts, its copy of the binary verifies its
  local witnesses prove it is in the frame its `<project>.dhall` describes, or exits 1 (§ X).
- The `context-init` step's reconcile action: mint the callee's child `<project>.dhall` (parameters +
  context + witness, never the chain shape) from the active parent config just before the recursive handoff
  into the next frame, re-homing the dissolved `context create vm|container|service` mutation verb (§ X,
  phase-15).
- Restartability: a `project up` re-run on a partially built stack reconciles each frame to running without
  redoing completed work (idempotent reconcile-to-running).

#### Validation

- Unit tests in `ChainSpec` proving the argv fold for the recursive handoff is pure (§ K: only the
  outermost host dispatch names a resolver-mapped absolute path; every nested tool is the target's own bare
  `$PATH` name), the per-frame fail-fast rejects a wrong-frame witness before side effects, and the
  `context-init` step derives a child config that names the next frame.
- A dry-run test proving the interpreter renders the same `chain cfg` value it would execute (the
  single representation, § W).
- `cabal test all` from `core/` passes with `ChainSpec` included.

#### Remaining Work

The pure interpreter core is implemented and unit-tested (`HostBootstrap.Chain` + `ChainSpec`):
`renderChain` (the `--dry-run` plan), `nextFrameAfter` (the descent order), `handoffDispatch` (the
recursive `project up` argv fold over `HostBootstrap.Lift.foldLift`, honouring § K), the effectful
`runChainFromFrame` seam (run this frame's steps, then hand off `project up` into the next frame, fail-closed
on a non-zero handoff), and the dry-run==apply single-representation invariant. The **multi-frame recursive
descent is now real-run-validated on Incus/Linux**: a real `project up` ran the metal segment (provision VM →
build pb #2 → build image #3), then the metal→VM handoff (`incus exec <vm> -- /usr/local/bin/hostbootstrap-demo
project up`) and the VM→container handoff (`docker run <image> project up`) both **succeeded** — the
`context-init` step minted the `vm-project-container-2` child config (`deriveContainerContext` /
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

- `project init` — fail-fast unless run as a fresh host-level binary with no sibling `<project>.dhall`;
  writes the root config (host-orchestrator, no parent) with optional `--cpu` / `--memory` / `--storage` /
  `--ha-replicas` (§ O, § Y). Python does not trigger it after the host-native build (§ M); the Dockerfile
  build-time authority surface is the `project init`-family equivalent of the former
  `config init --role image-build-container`, still baked before `check-code` (§ R, phase-15).
- `project up` — interprets the chain recursively from the current frame (Sprint 16.2); idempotent
  reconcile-to-running; `--dry-run` renders the pure `chain cfg` `[Step]` value without acting (§ W).
- `project down` — stops service/VM frames and deletes kind clusters while preserving durable state. VM
  frames use the provider stop-without-delete capability (incus/Lima **stop**, not destroy); kind clusters
  are deleted because kind has no reliable stop/restart contract. Best-effort and idempotent so a partial
  stack always tears down.
- `project destroy` — runs `down`, then deletes everything that was spun up; durable host `.data` is always
  preserved (the never-delete-`.data` invariant, § O).
- Command gating: `project init` and the read-only `context` command are the only normal entrypoints (with
  help/version) allowed without an existing sibling context; all other `project` verbs gate through the
  sibling `<project>.dhall` (§ X). Project commands cannot shadow these core verbs (§ P).

#### Validation

- `CommandSpec` unit tests proving `project init` fail-fast when a sibling config already exists,
  `project up --dry-run` renders the pure chain through the gate, `project down` issues stop (not delete)
  to the VM provider, and `project destroy` deletes while leaving `.data` intact.
- Tests proving the lifecycle verbs gate through the active context and are accepted only in contexts that
  authorize them (§ X).
- `cabal test all` from `core/` and `cabal build all` from `demo/` pass.

#### Remaining Work

None. The `project init|up|down|destroy` surface ships on the core optparse tree
(`HostBootstrap.Command.projectCommandGroup`), with the chain and the chain-frame teardown threaded through
`ProjectSpec` (`psChain` / `psFrameContext` / `psTeardown`, attached with `withChain` / `withFrameContext` /
`withTeardown`). `project up --dry-run` renders `chain cfg` through the context gate; the apply path
(`runChainFromFrame`) is **real-run-validated end-to-end on Incus/Linux** — a real `project up` provisioned
the VM, built the demo binary host-native in it (build #2, self-proved with `context schema`), and built the
project image FROM the published base in it (build #3), exiting 0. `project down` runs the recursive cluster
teardown (host `.data` preserved, § O) then **stops** the VM (incus/Lima `stop`, the new stop-without-delete)
— validated leaving the VM `STOPPED`; `project destroy` runs the cluster delete (host `.data` preserved) then
**deletes** the VM (guard-prefixed, best-effort) — validated leaving the VM gone. The pure argv contract
(`stopVMArgs` = stop-not-delete, guarded `destroyVMArgs` / `deleteVMArgs` = delete) is unit-tested in
`IncusSpec` / `LimaSpec`. The flat `cluster` / `config init` / `context create` verbs are already removed from
the core tree (`coreCommandNames` = `context` / `project` / `test` / `service` / `check-code`; no hidden
commands); the demo's own legacy `vm` / `harbor` / `web` / `deploy` / `role` / `incus` verbs are dissolved
with the demo chain migration (Sprint 16.4, tracked in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).

### Sprint 16.4: Demo chain migration onto the core interpreter [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`, `demo/src/HostBootstrapDemo/Chain.hs`
**Docs to update**: `documents/engineering/authoring_project_binaries.md`, `documents/engineering/derived_project_standards.md`, `documents/operations/demo_runbook.md`

#### Objective

Migrate the worked demo from hand-written orchestration verbs to a contributed `chain :: cfg ->
[Step]` value plus step actions interpreted by the core lifecycle command, demonstrating the
workload-extension seam (§ T, § Y).

#### Deliverables

- The demo contributes its chain value — host-pb → deploy VM (Lima on Apple Silicon, Incus on Linux) →
  copy source + ensure GHC in the VM → build pb in the VM → ensure Docker in the VM → build the project
  image → deploy kind → deploy harbor → launch the webservice → expose the NodePort to the host — as a
  `[Step]` value, interleaving core host-management steps with the demo's own deploy-harbor / launch-web /
  role step kinds.
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
- A real-run-gated `project up` on a supported host (Lima on Apple Silicon, Incus on Linux) brings up the
  persistent stack and a follow-on `test run all` validates it (the decoupled test surface, § Z,
  phase-17).

#### Remaining Work

The metal-frame migration is **done and real-run-validated**: the demo contributes
`demoChain :: ProjectConfig -> [Step]` (`demo/src/HostBootstrapDemo/Commands.hs`), wired via `withChain` (and
the chain-frame teardown via `withTeardown`) in `demo/app/Main.hs`, and a real `hostbootstrap-demo project
up` on Incus/Linux ran the chain's three metal-frame steps end-to-end — ensure the VM provider → launch the
budget VM (cordon #1) → pristine-bootstrap (build #2 host-native + build #3 project image in the VM) —
exiting 0, with `project down` / `project destroy` stopping / deleting the VM (host `.data` preserved).
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
  core tests still green). The demo's six container-frame steps drive: `context-init` (mint the
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
  `project down` stopped the VM and `project destroy` deleted it, both `kind delete cluster` + host `.data`
  preserved (§ O). Handoff plumbing landed: the build-#2 in-VM pb + its sibling `.dhall` install at
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

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` - canonical home of the model: the chain `[Step]`
  value as the single representation, `project up` as its recursive/fractal interpreter, and the Python
  bootstrapper as the metal-frame instance of the fractal bootstrap.
- `documents/architecture/hostbootstrap_core_library.md` - the surfaced core command tree
  (`project init|up|down|destroy`, `context`, `test init|run`, `check-code`) and the `Step` algebra a
  project extends with its chain.
- `documents/architecture/library_hierarchy.md` - extension-stream stream 1 is the lift chain (`[Step]`, core +
  project step kinds).
- `documents/architecture/binary_context_config.md` - the `context-init` chain step mints child configs,
  `context` is read-only, and `.dhall` is parameters + context + witness with per-frame fail-fast on the
  handoff.

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
