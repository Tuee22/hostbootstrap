# Phase 14: Composable-Operation Algebra and Composition Methodology

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Frame `hostbootstrap-core`'s foundational composition model — a binary composes
> **operations** and crosses execution-context boundaries by invoking itself (the self-reference lift,
> Phase 11) — and document the deploy ≡ business-logic unification, leaving the concrete L1 business-logic
> primitives out of scope.

## Phase Status

**Status**: Done

The composition methodology is documented and the foundational primitive is `HostBootstrap.Lift` (Phase
11). This phase owns the operation taxonomy, the deploy = business-logic unification, the foundational
principles, and the L0 role-lifecycle skeleton on which L1 builds concrete business-logic primitives
(roles, topologies, policies). The operation *interface* is the documented taxonomy, not a Haskell
typeclass; reconcilers stay `HostConfig -> IO ()` and do not carry a threaded lift context.

The single-representation doctrine is part of the methodology: one operation has one representation. The
standardized test harness is the one representation of the test/deploy workflow; consumers lift the whole
`test all` workflow into the nested context instead of building a second cluster/deploy/e2e chain beside
it. The worked demo follows this shape with `test all` lifted into the project container in the managed
VM.

The topology-aware composition path is validated by the full real demo lifecycle: Dhall expresses the
complete topology, current frame, and runtime witnesses needed for a binary to fail fast outside its legal
execution context, and the worked demo lifts the whole `test all` workflow as the single representation
into the project container in the managed Lima VM (`3/3 passed`, including Playwright e2e; see Sprint 14.4).

## Remaining Work

None.

## Phase Objective

Land the foundational composition model in `hostbootstrap-core` and its documentation: operations as the
composable unit, the self-reference lift as the context-crossing operation (Phase 11), the deploy ≡
business-logic unification, and the L0 role-lifecycle skeleton — so a consumer composes any chain of
operations across contexts through the four-stream merge without L0 changes (see
[development_plan_standards.md § T, § U](development_plan_standards.md)).

## Sprints

### Sprint 14.1: Composition methodology and cookbook docs [Done]

**Status**: Done
**Implementation**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`, `documents/engineering/authoring_project_binaries.md`, `DEVELOPMENT_PLAN/development_plan_standards.md` (§ U)
**Docs to update**: `documents/README.md`, `README.md`

#### Objective

Document the composable-operation algebra, the self-reference lift, the deploy ≡ business-logic
unification, the foundational principles, and the L0/L1/L2 layering, and rewrite § U from the two-case
`HostTarget` to the n-level lift.

#### Deliverables

- `composition_methodology.md` (architecture, authoritative): the operation taxonomy, the lift, the
  deploy ≡ business-logic unification, the three foundational principles, and the layering.
- `composition_patterns.md` (engineering): the cookbook of context topologies, operation kinds, and
  business-logic shapes.
- `authoring_project_binaries.md` (engineering): the authoring how-to for a new consumer.
- § U rewritten (`Local | InVM` → the n-level self-reference lift); the new docs indexed and backlinked.

#### Validation

- `HostBootstrap.DocValidator` (run through the code-check) passes on all new/edited docs (metadata,
  TL;DR for architecture, resolving relative links, taxonomy). `cabal test` passes.

#### Remaining Work

None.

### Sprint 14.2: The role-lifecycle skeleton [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`, `core/hostbootstrap-core/test/RoleLifecycleSpec.hs`, `demo/src/HostBootstrapDemo/Role.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/architecture/run_models.md`

#### Objective

Land the L0 role-lifecycle skeleton (Load → Prereq → Acquire → Ready → Serve → Drain → Exit) with callback
injection — the `HostDaemon` run-model's substrate on which L1 builds concrete roles. The operation
*interface* is the documented taxonomy (a conceptual unification), **not** a Haskell typeclass:
reconcilers stay `HostConfig -> IO ()` (no threaded context), per the composition methodology.

#### Deliverables

- `HostBootstrap.RoleLifecycle`: the `RolePhase` enum + the pure `rolePhases` ordering, the `RoleSpec`
  record (acquire/serve/drain callbacks), and `runRole` (drives the lifecycle, draining via `finally`).
- A real consumer: the demo's F2 role (`HostBootstrapDemo.Role`) drives `roleServe` through `runRole`, so
  the skeleton is exercised, not dead code. The concrete bus/store/role primitives (declared topologies,
  batching/scheduler policy, the lifecycle reconciler, the WAN-egress hydrator) remain **L1
  (`daemon-substrate`)** work, out of scope.

#### Validation

- `RoleLifecycleSpec` asserts the phase ordering and that `runRole` acquires→serves→drains (and drains
  even when serving throws). The demo's `role serve`/`submit` round-trips through `runRole`. `cabal test`
  passes (134 tests).

#### Remaining Work

None.

### Sprint 14.3: Single-representation doctrine — the test workflow is a lifted operation [Done]

**Status**: Done
**Implementation**: `documents/architecture/composition_methodology.md`, `DEVELOPMENT_PLAN/development_plan_standards.md` (§ W)
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`

#### Objective

Capture the **single-representation doctrine** as the methodology's worked refinement of the operation
algebra: an operation has exactly **one** representation. The standardized test harness
(`HostBootstrap.Harness`: `runMatrix` + `Seams`) **is** that one representation for the cluster-deploy
workflow — the context-agnostic test engine that brings up an isolated per-case environment, runs the
case body, and tears it down, invoking its reconcilers (e.g. `clusterUp`) as `HostConfig -> IO ()`
"locally", unaware of any enclosing context. The harness is therefore a **lift target**, not a lift-aware
component (no `LiftContext` inside it — per the self-reference-lift rule, § U), and that is correct. A
consumer composes its deploy as a **single** explicit lift sequence (§ U) whose final compute step
**lifts the whole test workflow** into the project container in the VM — folding to
the selected VM provider followed by `docker run --rm <image> test all` — so the harness runs `clusterUp`
"locally" on the VM's Docker and the kind cluster lives **in the VM**. Re-expressing cluster bring-up / Harbor / web-serve
/ e2e as a **separate** chain of lifted ops alongside the harness is a **redundant representation** (it
duplicates the harness and double-creates clusters); there is one representation, and the harness is it.

#### Deliverables

- The doctrine is documented in `documents/architecture/composition_methodology.md` (the harness as the
  one representation, lifted; no parallel deploy chain) and stated as a contract in § W of the
  development-plan standards, cross-referencing § T (the harness/four-stream) and § U (the self-reference
  lift).

#### Validation

- `HostBootstrap.DocValidator` passes on the updated `composition_methodology.md` (metadata, TL;DR for
  architecture, resolving relative links). The standards § W cross-references § T and § U.

#### Remaining Work

None. The worked demo uses the single lift sequence with `test all` as the only lifted compute step in
`inContainer img (inVM vm localContext)`.

### Sprint 14.4: Context-aware arbitrary topology [Done]

**Status**: Done
**Implementation**: `documents/architecture/composition_methodology.md`, `documents/architecture/binary_context_config.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/src/HostBootstrap/Context.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/architecture/binary_context_config.md`, `documents/engineering/dhall_topology.md`, `documents/engineering/composition_patterns.md`

#### Objective

Encode arbitrary lifted execution topology as pure data: a list of provider-backed frames, parent links,
a current frame, and runtime witnesses. This must support arbitrary composition depth, such as host ->
VM -> container -> cluster -> service pod, or host -> VM -> Pulumi role -> EKS cluster -> workload,
without making illegal states representable.

#### Deliverables

- Document the frame graph shape and why it is open-ended rather than a fixed recursive Incus/container
  stack.
- Define how command gates combine context kind, command class, capabilities, current frame, ancestors,
  and runtime witnesses.
- Define the implementation obligation for provider-specific witnesses.
- Align `HostBootstrap.Lift` terminology with provider-backed VM frames rather than Incus-only VM frames.

#### Validation

- Documentation validator passes on the updated architecture docs.
- Core tests cover provider-backed lift folds.
- The full Apple Silicon Lima demo lifecycle validates the single-representation lift in a real VM:
  `test all` is lifted as one project-container workflow and reports `3/3 passed`, including e2e.

Current validation: the frame/witness topology shape is implemented in Phase 15; `cabal test all` from
`core/` passes (199 tests); `cabal build all` from `demo/` passes; and `cabal run hostbootstrap-demo --
deploy --dry-run` renders the six-step chain where the only lifted compute step remains `test all` and
the preceding VM-local step materializes the runtime config.

#### Remaining Work

None. The full real Apple Silicon Lima demo lifecycle validates the single-representation lift in a real
VM (2026-06-16): the only lifted compute step is `test all`, folded to
`limactl shell hostbootstrap-demo-vm -- docker run --rm … hostbootstrap-demo:local test all`, with the
per-case kind clusters coming up on the VM's Docker and `test report: 3/3 passed` including the `e2e-tabs`
Playwright case (`DEMO_DEPLOY_EXIT=0`, guarded `vm down`).

### Sprint 14.5: Credential forwarding across the lift [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs` (`liftSubcommandWithAuth`), `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs` (`runToolWithStdin`), `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Chain.hs`, `demo/app/Main.hs`, `core/hostbootstrap-core/test/RegistrySpec.hs`
**Docs to update**: `documents/engineering/registry_credentials.md`, `documents/architecture/composition_methodology.md`, `documents/architecture/binary_context_config.md`, `documents/operations/demo_runbook.md`

#### Objective

Generalize the lift so a project binary forwards the host's Docker Hub login into nested contexts to
authenticate image pulls (avoiding the unauthenticated rate limit), modelled so the credential is never
represented in Dhall, never persisted in the VM/cluster, and never placed in `argv`.

#### Deliverables

- `HostBootstrap.Registry`: the opaque, non-serialisable `RegistryAuth` (no Dhall codec, redacted `Show`),
  host-only discovery (`discoverHostRegistryAuth`, Docker-Hub-only projection), the `stdin` →
  ephemeral-`DOCKER_CONFIG` wrapper (`dockerAuthStdinWrapper`), and the in-container consume-once bracket
  (`withForwardedRegistryAuth`).
- `liftSubcommandWithAuth` (`HostBootstrap.Lift`) forwards the credential into a container-through-a-VM
  frame over `stdin` plus `-e HOSTBOOTSTRAP_REGISTRY_AUTH` (the name only); `runToolWithStdin` is the
  stdin-capable tool runner.
- The demo wires it: build #3's base pull is authenticated, the lifted `test all` forwards into the
  container so its `kind`/e2e pulls authenticate, and the in-container binary consumes the forwarded
  credential once into an ephemeral `DOCKER_CONFIG`. Anonymous fallback when the host is not logged in.

#### Validation

`cabal test all` from `core/` passes (199 tests) with `RegistrySpec` covering the Docker-Hub-only
projection, the redacted `Show`, the `Nothing` anonymous fallback, and that the `stdin` wrapper embeds no
secret; `cabal build all` from `demo/` passes; `fourmolu --mode check` on the demo `app`/`src` is clean.
The authenticated full Apple Silicon Lima lifecycle (2026-06-16) pulled the base image and the
in-container `kind`/e2e images with **no** unauthenticated rate-limit error and reported
`test report: 3/3 passed`, including the multi-browser `e2e-tabs` (9 Playwright runs: 3 specs ×
chromium/firefox/webkit). The credential never appeared in Dhall, a persisted file, or `argv`.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` - the operation algebra, the self-reference lift,
  and the deploy ≡ business-logic unification, including the single-representation doctrine — the
  standardized test harness is the one representation, lifted into the VM-container, with no parallel
  deploy chain alongside it (cross-references standards § W, § T, § U).

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` - the shape cookbook (created).
- `documents/engineering/authoring_project_binaries.md` - the authoring how-to (created).
- `documents/engineering/registry_credentials.md` - forwarding the host Docker Hub login down the lift to
  authenticate nested pulls, modelled (`HostBootstrap.Registry`) so the credential is never in Dhall,
  never persisted, and never in `argv` (created).

**Cross-references to add:**
- `documents/README.md` indexes the three new docs; `system-components.md` carries the
  `HostBootstrap.Lift` row; `development_plan_standards.md` § U is rewritten to the n-level lift.
