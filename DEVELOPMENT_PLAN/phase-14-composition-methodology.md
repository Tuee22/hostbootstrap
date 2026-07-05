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

**Reopened (2026-06-19) and closed (2026-06-20):** the single-representation doctrine is corrected — in both
code and the canonical doc — so the standardized test harness **reuses the chain** (drives `project up`)
rather than re-expressing bring-up as a separate seam path. `composition_methodology.md` carries the recast:
the chain `[Step]` value is THE single representation, `project up` is its recursive/fractal interpreter,
the Python bootstrapper is the metal-frame instance, the harness-drives-`project up` vs separate-seam-path
WRONG/RIGHT block, and the multi-role-config note — with a `## Current Status` recording the validated build
(full `project up` + `test run all 3/3` on both Incus/Linux and a 16 GiB Apple-Silicon host). The behaviour
is enforced in code (the stack-driven `TestSuite`, [phase-10](phase-10-standardized-test-harness.md)) and
real-run-validated ([phase-13](phase-13-hostbootstrap-demo.md)). See `## Remaining Work`.

The composition methodology is documented and the foundational primitive is `HostBootstrap.Lift` (Phase
11). This phase owns the operation taxonomy, the deploy = business-logic unification, the foundational
principles, and the L0 role-lifecycle skeleton on which L1 builds concrete business-logic primitives
(roles, topologies, policies). The operation *interface* is the documented taxonomy, not a Haskell
typeclass; reconcilers stay `HostConfig -> IO ()` and do not carry a threaded lift context.

The single-representation doctrine is part of the methodology: one operation has one representation. The
methodology is **recast** around the **"chain is the project"** model: a project's deploy is its **lift
chain** — a pure `chain :: cfg -> [Step]` value that *is* the project's identity (§ W) — and that
`[Step]` chain is the single representation. `composition_methodology.md` (the canonical home) and
`composition_patterns.md` present `project up` as the recursive/fractal interpreter of that chain and the
Python bootstrapper as the metal-frame instance of the fractal bootstrap, with an honest `## Current Status`
separating the built primitives from the real-run-gated apply. The interpreter primitive
(`HostBootstrap.Chain`) and the `project` command exist and are unit-tested (phase-16); their effectful
end-to-end provisioning is real-run-gated and owned by phase-16.

The topology-aware composition path is validated by the full real demo lifecycle: Dhall expresses the
complete topology, current frame, and runtime witnesses needed for a binary to fail fast outside its legal
execution context, and the worked demo lifts the whole `test all` workflow as the single representation
into the project container in the managed Lima VM (`3/3 passed`, including Playwright e2e; see Sprint 14.4).

Forward-pointer: the **composition pattern #7** re-anchor — from a build-only VM to the **headless host
build** (build on the bare host, stage the artifact into the cluster, never run the workload in a build VM),
whose first worked instance is the Windows `ensure cudawin` CUDA host build — is owned by
[phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md) (Sprint 3.4). The canonical cookbook home is
`composition_patterns.md`.

## Remaining Work

Recast the single-representation doctrine (§ W) so the standardized test harness **reuses the chain** — it
drives the real `project up` with a test-written config — instead of being a context-agnostic engine that
brings up an isolated per-case environment "locally". The harness is not a second representation lifted
alongside the chain; it *is* the chain, driven under a test config.

**Landed in code (2026-06-19):** the doctrine is now enforced in code, not only documented — the
stack-driven `HostBootstrap.Harness.TestSuite` makes the harness drive the real `project up` / `project
destroy` ([phase-10](phase-10-standardized-test-harness.md)), and the demo's second bring-up path
(`demoSeams`) is deleted. There is no longer a separate seam bring-up beside the chain.

**Delivered (2026-06-20), DocValidator-validated:** the single-representation section of
`composition_methodology.md` is recast — the harness driving `project up` is the RIGHT pattern and a
separate seam bring-up beside the chain is the WRONG one (an explicit WRONG/RIGHT block), one
`<project>.dhall` may declare multiple roles, and context relationships are pure compositional lifts. The
behavioural recast is enforced by the harness recast ([phase-10](phase-10-standardized-test-harness.md)) and
exercised by the demo's run ([phase-13](phase-13-hostbootstrap-demo.md)); the `project up` interpreter the
harness drives is owned by [phase-16](phase-16-project-lifecycle-command.md). No remaining work.

The sprints that built still-valid substrate (the role-lifecycle skeleton, the arbitrary-topology frame
graph, and credential forwarding across the lift) remain `Done`.

## Phase Objective

Land the foundational composition model in `hostbootstrap-core` and its documentation: operations as the
composable unit, the self-reference lift as the context-crossing operation (Phase 11), the deploy ≡
business-logic unification, and the L0 role-lifecycle skeleton — so a consumer composes any chain of
operations across contexts through the extension-stream merge without L0 changes (see
[development_plan_standards.md § T, § U](development_plan_standards.md)).

## Sprints

### Sprint 14.1: Composition methodology and cookbook docs [Done]

**Status**: Done
**Implementation**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`, `documents/engineering/authoring_project_binaries.md`, `DEVELOPMENT_PLAN/development_plan_standards.md` (§ U, § W, § Y)
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`, `documents/engineering/authoring_project_binaries.md`, `documents/README.md`, `README.md`

#### Objective

Document the composable-operation algebra, the self-reference lift, the deploy ≡ business-logic
unification, the foundational principles, and the L0/L1/L2 layering, and rewrite § U from the two-case
`HostTarget` to the n-level lift. **Recast** the methodology around the chain-is-the-project model: the
self-reference lift becomes the recursive `project up` interpreter of a pure `chain :: cfg ->
[Step]` value, with fractal bootstrap (provision -> build pb -> hand off `pb project up`) at every frame
and the Python bootstrapper as the metal-frame instance.

#### Deliverables

- `composition_methodology.md` (architecture, authoritative): the operation taxonomy, the lift, the
  deploy ≡ business-logic unification, the three foundational principles, and the layering. **(Built.)**
- `composition_patterns.md` (engineering): the cookbook of context topologies, operation kinds, and
  business-logic shapes. **(Built.)**
- `authoring_project_binaries.md` (engineering): the authoring how-to for a new consumer. **(Built.)**
- § U rewritten (`Local | InVM` → the n-level self-reference lift); the new docs indexed and backlinked.
  **(Built.)**

#### Validation

- `HostBootstrap.DocValidator` (run through the code-check) passes on all new/edited docs (metadata,
  TL;DR for architecture, resolving relative links, taxonomy). `cabal test` passes.

#### Remaining Work

The methodology docs describe the lift as the foundational context-crossing primitive, but they do **not**
yet present it as the recursive `project up` chain interpreter. The chain-is-the-project recast is the
open work:

- Recast `composition_methodology.md` (the **canonical home** of the model) so the self-reference lift is
  presented as the recursive `project up` interpreter of the pure `chain :: cfg -> [Step]` value;
  state chain-is-the-project; document fractal bootstrap (each frame transition = provision -> build pb ->
  hand off `pb project up`, with the Python bootstrapper as the metal-frame instance, § M); and frame the
  single-representation doctrine (§ W) as the `[Step]` chain being THE representation.
- Update `composition_patterns.md` to carry the chain/Step pattern + recursive interpreter as the
  canonical cookbook; align `authoring_project_binaries.md` so a consumer authors its `chain :: cfg
  -> [Step]` (plus step actions, test suite, artifacts, Dhall vocabulary) rather than noun verbs.
- Add a `## Current Status` to the recast docs. That status now reports both the built lift primitive
  (`HostBootstrap.Lift`) and the implemented `project` lifecycle command / `[Step]`-chain interpreter;
  phase 16 closed the interpreter after this docs recast.
- DocValidator must continue to pass (metadata block, TL;DR on the architecture doc, resolving relative
  links, taxonomy). This is a docs-only recast; the interpreter build is phase-16.

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
**Implementation**: `documents/architecture/composition_methodology.md`, `DEVELOPMENT_PLAN/development_plan_standards.md` (§ W, § Y, § Z)
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
"locally" on the VM's Docker and the kind cluster lives **in the VM**. Re-expressing cluster bring-up / registry / web-serve
/ e2e as a **separate** chain of lifted ops alongside the harness is a **redundant representation** (it
duplicates the harness and double-creates clusters); there is one representation, and the harness is it.

#### Deliverables

- The doctrine is documented in `documents/architecture/composition_methodology.md` (the harness as the
  one representation, lifted; no parallel deploy chain) and stated as a contract in § W of the
  development-plan standards, cross-referencing § T (the harness/extension-stream) and § U (the self-reference
  lift).

#### Validation

- `HostBootstrap.DocValidator` passes on the updated `composition_methodology.md` (metadata, TL;DR for
  architecture, resolving relative links). The standards § W cross-references § T and § U.

#### Remaining Work

The single-representation doctrine is documented, but it is framed around the deploy as a hand-written
single lift sequence whose only lifted compute step is `test all` (`inContainer img (inVM vm
localContext)`). The chain-is-the-project recast changes that contract:

- Restate the single representation as the pure `chain :: cfg -> [Step]` value (§ W, § Y): `project
  up` is its recursive interpreter and `--dry-run` renders the same value apply executes. There is no
  second hand-written orchestration path beside the chain — the deploy sequence the demo carries today is
  superseded by the `[Step]` chain the core interprets.
- Decouple the test surface from deploy (§ Z): `project up` brings up a **persistent** stack; `test run
  all` is a **separate**, root-gated operation that validates that running stack. The standardized harness
  remains the one lift-target engine; document that `test run all` (not a lifted deploy chain) is how the
  live `project up` stack is validated. Re-expressing deploy bring-up as a parallel chain of lifted ops
  alongside the chain would be a redundant representation.
- Update `composition_methodology.md` and `composition_patterns.md` accordingly, with a `## Current
  Status` separating the built lift/harness from the target `project up` chain interpreter and the
  decoupled `test run all` surface (phase-16/phase-17). Do **not** claim `project`/`test run` is
  implemented. DocValidator must continue to pass.

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
