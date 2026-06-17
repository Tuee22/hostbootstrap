# Phase 16: Project Lifecycle Command And Step-Chain Interpreter

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [00-overview.md](00-overview.md), [README.md](README.md)

> **Purpose**: Build the `Step` algebra, the recursive/fractal chain interpreter, and the
> `project init|up|down|destroy` lifecycle command so a project's deploy is exactly the pure
> `chain :: RootConfig -> [Step]` value the core interprets — the single representation of its
> deployment (§ W, § Y).

## Phase Status

**Status**: Active

This phase owns the **new** surface the "chain is the project" model targets: the `Step` algebra, the
recursive interpreter, and the `project` lifecycle command, built on the reopened substrate phases —
phase-4 (the composable optparse command tree and entrypoint, § P), phase-5 (the cluster bring-up/teardown
reconcilers the chain interprets as steps), phase-14 (the self-reference lift generalized into the recursive
`project up` interpreter framing, § U), and phase-15 (the binary-context contract the per-frame fail-fast
handoff rests on, § X).

Sprint 16.1 — the `Step` algebra (`HostBootstrap.Step`) — is `Done` and unit-tested (`StepSpec`). The
recursive interpreter (Sprint 16.2), the `project init|up|down|destroy` command (Sprint 16.3), and the demo
chain migration (Sprint 16.4) are the remaining work; the code still carries the old topology (the flat
`cluster up|down|delete|status` verb, `config init` / `config show|schema|render`, `context create
vm|container|service`, and the demo's hand-written `demoDeployChain` plus the `deploy`/`vm`/`incus`/`harbor`/
`web`/`role` verbs), tracked `Pending` in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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
  `project up --dry-run` rendering the pure `chain rootCfg` `[Step]` value (the single representation, § W).
- Hold the doctrine that the sibling `<project>.dhall` carries **parameters + context + witness**, never
  the chain shape; each frame verifies it is in the frame its `<project>.dhall` describes, or fails fast
  (§ X); optional structural variation (skip the VM, deploy straight to Docker) is a root-`<project>.dhall`
  flag so the chain stays a pure function of root parameters.
- Add the new VM stop-without-delete capability so `project down` stops services/clusters/VMs without
  deleting them and `project destroy` deletes everything spun up while preserving durable host `.data`
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

### Sprint 16.2: The recursive/fractal chain interpreter [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`, `core/hostbootstrap-core/test/ChainSpec.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/src/HostBootstrap/Context.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`, `documents/engineering/dhall_topology.md`

#### Objective

Interpret a pure `chain :: RootConfig -> [Step]` value recursively across the composed frame stack, so
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
- A dry-run test proving the interpreter renders the same `chain rootCfg` value it would execute (the
  single representation, § W).
- `cabal test all` from `core/` passes with `ChainSpec` included.

#### Remaining Work

The pure interpreter core is implemented and unit-tested (`HostBootstrap.Chain` + `ChainSpec`):
`renderChain` (the `--dry-run` plan), `nextFrameAfter` (the descent order), `handoffDispatch` (the
recursive `project up` argv fold over `HostBootstrap.Lift.foldLift`, honouring § K), the effectful
`runChainFromFrame` seam (run this frame's steps, then hand off `project up` into the next frame, fail-closed
on a non-zero handoff), and the dry-run==apply single-representation invariant. Remaining
(**real-run-gated**, § C): the `context-init` step's reconcile action wired to
`deriveProjectConfigForKind` / `writeProjectConfigFile`, the per-frame fail-fast handoff wired through the
live binary-context gate (`HostBootstrap.Context`), and end-to-end provisioning validated by a real
`project up` run — landed with the lifecycle command (Sprint 16.3) and the demo chain (Sprint 16.4).

### Sprint 16.3: The `project init|up|down|destroy` lifecycle command [Blocked]

**Status**: Blocked
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`, `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`, `core/hostbootstrap-core/test/CommandSpec.hs`
**Blocked by**: 16.2 (the recursive interpreter), 4.x (the composable optparse command tree and entrypoint), 5.x (cluster bring-up/teardown reconcilers and stop-without-delete)
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/cluster_lifecycle.md`, `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/operations/demo_runbook.md`

#### Objective

Surface the recursive lifecycle command `project init|up|down|destroy` on the core optparse tree (§ P) and
drive the chain interpreter from it.

#### Deliverables

- `project init` — fail-fast unless run as a fresh host-level binary with no sibling `<project>.dhall`;
  writes the root config (host-orchestrator, no parent) with optional `--cpu` / `--memory` / `--storage` /
  `--ha-replicas` (§ O, § Y). Python triggers it idempotently after the host-native build (§ M); the
  Dockerfile build-time authority surface is the `project init`-family equivalent of the former
  `config init --role image-build-container`, still baked before `check-code` (§ R, phase-15).
- `project up` — interprets the chain recursively from the current frame (Sprint 16.2); idempotent
  reconcile-to-running; `--dry-run` renders the pure `chain rootCfg` `[Step]` value without acting (§ W).
- `project down` — stops services / clusters / VMs without deleting them, using the new VM
  stop-without-delete capability (incus/Lima **stop**, not destroy); recurses in while each frame is still
  up, then stops on ascent; best-effort and idempotent so a partial stack always tears down.
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

The `project init|up|down|destroy` command, the new VM stop-without-delete capability, and the
`--dry-run` chain rendering are the target being built; nothing is implemented. The flat
`cluster up|down|delete|status` verb (`HostBootstrap.Command`) and the standalone `config init` verb are
superseded by these lifecycle verbs and are tracked `Pending` in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Sprint 16.4: Demo chain migration onto the core interpreter [Blocked]

**Status**: Blocked
**Implementation**: `demo/src/HostBootstrapDemo/Chain.hs`, `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`, `demo/docker/Dockerfile`, `demo/test/DemoChainSpec.hs`
**Blocked by**: 16.3 (the lifecycle command), 13.x (the worked demo chain), 15.x (per-frame context gating)
**Docs to update**: `documents/engineering/authoring_project_binaries.md`, `documents/engineering/derived_project_standards.md`, `documents/operations/demo_runbook.md`

#### Objective

Migrate the worked demo from hand-written orchestration verbs to a contributed `chain :: RootConfig ->
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

The demo chain value, its step actions, and the dissolution of the demo verbs are the target being built;
nothing is implemented. The demo `deploy` / `vm` / `incus` / `harbor` / `web` / `role` verbs and the
hand-written `demoDeployChain` (`demo/src/HostBootstrapDemo/Chain.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`) are superseded by the core `Step` interpreter plus the demo's
contributed chain value and step actions, and are tracked `Pending` in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The real-run validation of `project up`
and the decoupled `test run all` surface are owned with phase-17
([phase-17-chain-driven-test-and-context-introspection.md](phase-17-chain-driven-test-and-context-introspection.md)).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` - canonical home of the model: the chain `[Step]`
  value as the single representation, `project up` as its recursive/fractal interpreter, and the Python
  bootstrapper as the metal-frame instance of the fractal bootstrap.
- `documents/architecture/hostbootstrap_core_library.md` - the surfaced core command tree
  (`project init|up|down|destroy`, `context`, `test init|run`, `check-code`) and the `Step` algebra a
  project extends with its chain.
- `documents/architecture/library_hierarchy.md` - four-stream stream 1 is the lift chain (`[Step]`, core +
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
  `chain :: RootConfig -> [Step]` (plus step actions, test suite, artifacts, Dhall vocabulary), not noun
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
