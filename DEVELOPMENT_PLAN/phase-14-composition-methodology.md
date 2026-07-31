# Phase 14: Composition methodology

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Frame `hostbootstrap-core`'s foundational composition model — a binary composes
> **operations** and crosses execution-context boundaries by invoking itself (the self-reference lift,
> Phase 11) — and document the deploy ≡ business-logic unification, leaving the concrete L1 business-logic
> primitives out of scope.

## Phase Status

**Status**: Active
**Blocked by**: Sprint 16.6 for Sprint 14.6's remaining `service run` call-site adoption; Sprint 14.7 is
closed

**Extended 2026-07-25.** Sprint 14.7 reopens the generic network-planning boundary: raw endpoint text
and an independently serialized redirect default currently permit a host-local registry client to be
redirected to a cluster-only object store. The target makes delivery a reachability-proof-gated part of
the same finalized plan.

**Reopened 2026-07-24; the engine landed 2026-07-30.** The methodology documents remain valid. The L0
`RoleLifecycle` skeleton had no production consumer after the demo `Role` module and appended role verbs
were removed, and a definition-only public callback engine could not remain as a second lifecycle
representation. Sprint 14.6 deleted it and replaced it with the phase-indexed engine; what is still open
there is the `service run` call-site adoption, which waits on Sprint 16.6's root-authorized `project up`
gate, because until that lands nothing in production can sign an activation manifest.

**Earlier reopening (2026-06-19) and closure (2026-06-20):** the methodology removed a parallel harness bring-up
graph: the standardized test harness **reuses the chain** (drives `project up`) rather than expressing
deployment through a second seam path. `composition_methodology.md` records `project up` as the
recursive/fractal interpreter, the Python bootstrapper as the metal-frame instance, and the
harness-drives-`project up` rule. The dated `3/3` runs are historical evidence for that narrower result.
The later audit found that the chain, the per-frame context, and the teardown were three independent
lifecycle views; Phase 16.6, not this completed methodology phase, owns their replacement with one opaque
plan. All three were unified 2026-07-30: forward execution always was, the per-frame descent is declared
with `descendsVia`, and the reverse effect with `reversedBy`. What remains of Phase 16.6's ownership is
the recursive child-first unwind that drives the reverse projection into every acquired frame.

The composition methodology is documented and the foundational primitive is `HostBootstrap.Lift` (Phase
11). This phase owns the operation taxonomy, the deploy = business-logic unification, the foundational
principles, and the L0 role-lifecycle skeleton on which L1 builds concrete business-logic primitives
(roles, topologies, policies). The operation *interface* is the documented taxonomy, not a Haskell
typeclass. Current live reconcilers commonly have the historical `HostConfig -> IO ()` shape; Phase 9.10
now supplies typed transition descriptors and `ReconcileResult`, while this phase owns the
role-lifecycle and network-plan consumers.

The single-representation doctrine is part of the methodology: one operation has one representation.
Today opaque validated `StepPlan` is the one **forward ordering** and the harness adds no second
deployment graph; it is not yet the complete lifecycle representation because frame context and
teardown are separate checked contributions. `composition_methodology.md` (the canonical home) and
`composition_patterns.md` present `project up` as the recursive/fractal interpreter of that plan, the
target resource-indexed lifecycle plan, and the
Python bootstrapper as the metal-frame instance of the fractal bootstrap. The interpreter primitive
(`HostBootstrap.Chain`) and the `project` command exist and are unit-tested (phase-16); their effectful
end-to-end provisioning is real-run-gated and owned by phase-16.

The topology-aware composition path has dated real-demo evidence: Dhall expressed the topology, current
frame, and runtime witnesses needed for a binary to fail fast outside its legal execution context.
Sprint 14.4 records the 2026-06-16 run that lifted the then-current `test all` workflow into a Lima VM.
That historical command shape is not the current single-representation doctrine: today the project-owned
`[Step]` value is the sole forward-order input, `project up` interprets it, and the harness reuses that
command per variant. Frame context and teardown remain independent callbacks; Sprints 19.8 and 16.6 own
the one validated lifecycle representation.

Forward-pointer: the **composition pattern #7** re-anchor — from a build-only VM to the **headless host
build** (build on the bare host, stage the artifact into the cluster, never run the workload in a build VM),
whose first worked instance is the Windows `ensure cudawin` CUDA host build — is owned by
[phase-3-ensure-reconcilers.md](phase-3-ensure-reconcilers.md) (Sprint 3.4). The canonical cookbook home is
`composition_patterns.md`.

## Remaining Work

Sprint 14.6 integrates the definition-only role skeleton into the fixed service runtime with the same
plan/phase authority model. Sprint 14.7 adds scope-indexed endpoints and proof-gated blob delivery.
Open ownership, profile-isolation, and recursive-teardown defects remain owned by Phases 9, 10, 13,
and 16.

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

None. The chain-is-the-project recast, recursive `project up` framing, fractal-bootstrap explanation,
authoring guidance, and status separation all landed. Phase 16 owns the interpreter and its still-open
single-plan/recursive-teardown repair.

### Sprint 14.2: The role-lifecycle skeleton [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/architecture/run_models.md`

#### Objective

Land the initial L0 role-lifecycle skeleton (Load → Prereq → Acquire → Ready → Serve → Drain → Exit) with
callback injection—the historical substrate on which L1 could build concrete roles. The operation
*interface* is the documented taxonomy (a conceptual unification), **not** a Haskell typeclass. This
sprint records the initial skeleton, not the later typed reconciliation target.

#### Deliverables

- `HostBootstrap.RoleLifecycle`: the `RolePhase` enum + the pure `rolePhases` ordering, the `RoleSpec`
  record (acquire/serve/drain callbacks), and `runRole` (drives the lifecycle, draining via `finally`).
- Historical consumer evidence: the then-present demo F2 role drove `roleServe` through `runRole`. That
  demo module and its appended verbs were later removed; the current repository has no non-test
  `runRole` consumer. Sprint 14.6 owns the resulting definition-only surface.

#### Validation

- `RoleLifecycleSpec` asserts the phase ordering and that `runRole` acquires→serves→drains (and drains
  even when serving throws). The removed demo round-trip is historical evidence, not a current command
  or consumer.

#### Remaining Work

None in the initial skeleton scope. Sprint 14.6 owns current integration and type refinement.

### Sprint 14.3: Single-representation doctrine [Done]

**Status**: Done
**Implementation**: `documents/architecture/composition_methodology.md`, `DEVELOPMENT_PLAN/development_plan_standards.md` (§ W, § Y, § Z)
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`

#### Objective

Capture the **single-representation doctrine** as the methodology's worked refinement of the operation
algebra. The sprint's first 2026-06 framing treated the lifted harness workflow as the deployment
representation. The completed recast superseded that framing: the project-owned `[Step]` value is the
forward ordering, `project up` is its interpreter, and the context-agnostic harness drives that same
ordering per variant. It must not carry a second bring-up graph. Complete lifecycle unification is later
Phase 16.6 work.

#### Deliverables

- The doctrine is documented in `documents/architecture/composition_methodology.md` with one forward
  `[Step]` ordering and no parallel harness deployment graph; it also names the later opaque-plan target.
  The contract lives in § W of the development-plan standards, cross-referencing § T and § U.

#### Validation

- `HostBootstrap.DocValidator` passes on the updated `composition_methodology.md` (metadata, TL;DR for
  architecture, resolving relative links). The standards § W cross-references § T and § U.

#### Remaining Work

None. The completed correction makes the project-owned `[Step]` plan the representation and makes the
harness consume that lifecycle rather than define a second deployment path. Phase 16.6 owns the remaining
implementation defect that forward execution, frame selection, and reverse teardown are still supplied by
separate callbacks that can disagree.

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
- Historical 2026-06-16 evidence: the then-current Apple Silicon Lima demo lifted `test all` as one
  project-container workflow and reported `3/3 passed`, including e2e. This proves topology placement, not
  the superseded claim that the harness is the deployment representation.

Historical phase-close validation (superseded by the fixed command surface): the frame/witness topology
shape is implemented in Phase 15; `cabal test all` from
`core/` passes (199 tests); `cabal build all` from `demo/` passes; and `cabal run hostbootstrap-demo --
deploy --dry-run` renders the six-step chain where the only lifted compute step remains `test all` and
the preceding VM-local step materializes the runtime config.

#### Remaining Work

None. Historical topology evidence from the Apple Silicon Lima demo (2026-06-16) lifted `test all`, folded to
`limactl shell hostbootstrap-demo-vm -- docker run --rm … hostbootstrap-demo:local test all`, with the
per-case kind clusters coming up on the VM's Docker and `test report: 3/3 passed` including the `e2e-tabs`
Playwright case (`DEMO_DEPLOY_EXIT=0`, guarded `vm down`). That command shape is retained only as dated
evidence; current deployment is the project-owned `[Step]` lifecycle plan.

### Sprint 14.5: Credential forwarding across the lift [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs` (`liftSubcommandWithAuth`),
`core/hostbootstrap-core/src/HostBootstrap/Ensure.hs` (`runToolWithStdin`),
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`
**Docs to update**: `documents/engineering/registry_credentials.md`, `documents/architecture/composition_methodology.md`, `documents/architecture/binary_context_config.md`, `documents/operations/demo_runbook.md`

#### Objective

Generalize the lift so a project binary forwards the host's Docker Hub login into nested contexts to
authenticate image pulls (avoiding the unauthenticated rate limit), modelled so the credential is never
represented in Dhall, retained as durable project/image state, or placed in `argv`. Raw bytes necessarily
cross bounded stdin, process-environment, memory, and temporary-file effects.

#### Deliverables

- `HostBootstrap.Registry`: the opaque, non-serialisable `RegistryAuth` (no Dhall codec, redacted `Show`),
  host-only discovery (`discoverHostRegistryAuth`, Docker-Hub-only projection), the `stdin` →
  ephemeral-`DOCKER_CONFIG` wrapper (`dockerAuthStdinWrapper`), and the in-container consume-once bracket
  (`withForwardedRegistryAuth`).
- `liftSubcommandWithAuth` (`HostBootstrap.Lift`) forwards the credential into a container-through-a-VM
  frame over `stdin` plus `-e HOSTBOOTSTRAP_REGISTRY_AUTH` (the name only); `runToolWithStdin` is the
  stdin-capable tool runner.
- The demo wires it through recursive lift handoffs: nested base, kind, and e2e pulls authenticate, and
  the in-container binary consumes the forwarded credential once into an ephemeral `DOCKER_CONFIG`.
  Anonymous fallback applies when the host is not logged in.

#### Validation

`cabal test all` from `core/` passes (199 tests) with `RegistrySpec` covering the Docker-Hub-only
projection, the redacted `Show`, the `Nothing` anonymous fallback, and that the `stdin` wrapper embeds no
secret; `cabal build all` from `demo/` passes; `fourmolu --mode check` on the demo `app`/`src` is clean.
The authenticated full Apple Silicon Lima lifecycle (2026-06-16) pulled the base image and the
in-container `kind`/e2e images with **no** unauthenticated rate-limit error and reported
`test report: 3/3 passed`, including the multi-browser `e2e-tabs` (9 Playwright runs: 3 specs ×
chromium/firefox/webkit). The credential did not appear in Dhall, durable project/image state, or `argv`;
the transport's temporary `DOCKER_CONFIG` remained a bracketed effect rather than a persistent artifact.

#### Remaining Work

None.

### Sprint 14.6: One phase-indexed role lifecycle consumer [Active]

**Status**: Active
**Blocked by (remaining item only)**: Sprint 16.6

**Unblocked 2026-07-30.** Its prerequisite was the activation package Sprint 15.9 owns, and that landed
2026-07-29: `HostBootstrap.Activation` supplies `VerifiedRuntimeRoleActivation` (with its revision,
instance, service, permitted effects, and secret channel) and the one-use `reserveLifecycleAdmission`.
Sprint 15.9's own remaining work names **this** sprint as the owner of wiring activation into its live
call site, so continuing to mark 14.6 `Blocked by` 15.9 was circular.

**The engine landed 2026-07-30.** `HostBootstrap.RoleLifecycle` is no longer the definition-only
`RoleSpec` callback bag; it is the phase-indexed engine described under `Remaining Work`. The one item
still open is the `service run` call-site adoption, which is `Blocked by` Sprint 16.6 for the reason
recorded there.
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeRoleCursor.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/run_models.md`, `documents/architecture/hostbootstrap_core_library.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make the role lifecycle the single phase-indexed engine used by the fixed `service run` path instead of a
definition-only public callback skeleton.

#### Deliverables

- Replace the public result-free callback bag with an opaque
  `RolePlan scope specDigest planId configId secretDigest frame revision instanceId` and
  `RoleCursor scope planId frame instanceId phase`. `Load` remains only the historical Sprint 14.2 enum
  label: target activation/config/secret/role-plan verification and one-use lifecycle admission occur
  before cursor construction, and the sole initial cursor is Prereq. The core-owned engine privately
  drives Prereq → Acquire → Ready → Serve → Drain → Exit; no phase eliminator or live resource escapes to
  project code.
- Make `HostBootstrap.Service`/`service run` the production consumer. It must enter through
  the inseparable `VerifiedRuntimeRoleActivation` produced from a pinned project key, independently
  measured workload/OS/binary identity, and the broker-signed manifest. The manifest binds an immutable
  rollout revision/controller template before a workload exists; platform verification pairs it with a
  concrete instance ID (pod UID plus restart count or protected OS invocation nonce). Kubernetes installs
  immutable digest-addressed ConfigMap, Secret, and signed-manifest objects through one pod-template
  revision; the Secret is the sole secret-bearing object. A host daemon atomically switches one revision
  directory/pointer and mints a fresh invocation nonce on start. Startup verifies the actual wire and
  activation-bound private-channel bytes. Sprint 15.9 owns signing/key/provider-install authority; this sprint consumes that package and
  verifies the actual mounted
  role-wire bytes/private bundle through the matching finalized runtime spec into a fresh
  `VerifiedConfigWire scope configDigest configId` and scope-correct
  `ValidatedServiceRequest specDigest configId secretDigest fields service`, retains acquired receipts
  through drain, verifies the manifest's signed narrowed role-plan projection, validates its
  `rolePlanDigest`, and jointly mints
  `RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId` plus
  `VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects`
  while rebinding a
  fresh local generative `planId`. The narrowed child never claims it can hash the full lifecycle plan.
  Before Prereq/acquisition it atomically reserves the instance's one-use durable lifecycle admission, so
  a reusable activation/request cannot bind or spawn twice. Report structured acquire/serve/drain
  failures without skipping independent cleanup. This sprint
  supplies the exact workload-instance-indexed role plan/cursor/request/placement foundation. Phase
  18.6's sole `selectAndRunService` gate consumes it with the finalized registry, revalidates that exact
  instance identity and
  effect row, and privately mints/transfers the effect-indexed one-use service command authority;
  activation authority alone cannot run the handler or authorize an effect.
- Make failure branches carry their only legal successor. Pre-acquisition prerequisite failure reaches
  Exit only with `VerifiedNoRoleResources`. Full acquisition yields Ready plus the complete retained
  receipt/managed-handle set; failure after any acquisition yields only Drain plus every owned/unknown
  receipt. The readiness probe consumes the exact managed handles and yields identity-indexed ready
  handles plus Serve on success, or Drain plus retained receipts on timeout/terminal failure. Serve can
  use only those acquired-and-probed handles—there is no handler-visible later bind/spawn escape hatch. A
  restartable worker is represented by a stable supervisor handle; only a journal-prepared core
  transition may replace its child, and the successor must pass readiness before reuse. The retained
  resource package's lease requirement is derived conservatively from the signed placement's
  `permittedEffects` ceiling before Acquire, never selected by a caller. It inseparably contains every
  receipt/unknown and either proof that the ceiling prohibits every exclusive/mutating effect or the
  matching live `ServiceGenerationLease`. Phase 18's registry selection must prove its exact row is within
  that same ceiling, so mutation cannot appear on the no-lease branch; only the live lease can mint
  a prepared mutating effect, and Drain retains it until dependent cleanup settles. Serve
  completion, typed failure, or catchable controller shutdown and every partial-acquire/readiness failure
  therefore converge under masking on one drain interpreter, which attempts all independent releases,
  reprobes unknowns, aggregates failures, and alone yields Exit. Uncatchable process death is recovered
  from durable receipts by the controller/OS teardown path; it is not mislabeled an in-process drain.
- Remove any public constructor or compatibility path that can build an unrelated phase sequence, and
  remove the module entirely if the fixed service engine subsumes it under another canonical name.
- Keep Phase 9.10 as the owner of shared `ReconcileResult`; this sprint consumes that algebra rather than
  retaining `HostConfig -> IO ()` mutation callbacks.

#### Validation

- A source/API test proves `runRole` (or its replacement) has a non-test production consumer in
  `HostBootstrap.Service`, exposes only a terminal Exit report to project code, and requires no deleted
  demo module/path.
- Compile-fail tests reject serve-before-ready, drain without retained receipts, wrong config/plan/frame or
  revision/instance authority, direct construction of phase cursors, and any callback that captures live
  cursors/receipts/leases outside the core-owned runner.
- Fault-injection tests fail after every acquisition and readiness outcome. Each branch exposes only its
  typed successor, preserves all owned/unknown receipts for Drain, and cannot mint Ready/Serve from
  partial acquisition. A replace/rebind between probe and Serve cannot substitute a different
  listener/connection/worker handle. Catchable shutdown enters Drain exactly once; crash recovery
  rehydrates receipts and either cleans them up or reports an explicit unknown.
- Restart/race tests prove R1/I1 values cannot run in an R2/I2 workload and fail after exact I1
  terminates. A rolling overlap may keep non-exclusive R1/I1 live until controller shutdown. An
  exclusive/mutating lease transfer publishes R2/I2 only after the backend atomically enforces its fence,
  or after a retained-lock barrier settles or authoritatively fences every R1/I1 prepared/in-flight
  attempt; a backend with neither primitive is `Unsupported`. Every later R1/I1 prepare then refuses
  before the backend call. Pod recreation and a container restart in one pod UID produce distinct
  instance IDs.
- Runtime tests prove drain runs after serve failure, only owned receipts are released, and every
  independent cleanup failure is reported.

#### Remaining Work

**Delivered 2026-07-30 — the phase machine, the pre-cursor gate chain, and the removal of the callback
bag.**

`HostBootstrap.RoleLifecycle` no longer exports `RoleSpec`, `roleAcquire`, `roleServe`, `roleDrain`, or
`runRole`. What replaced them:

- **The gate chain runs before a cursor exists.** `verifyRolePlanDraft` compares the project's own
  non-empty draft against the manifest's signed `rolePlanDigest` with **no durable mutation**, then
  `withRoleLifecycleAdmission` atomically reserves the instance's one-use admission, then
  `withRuntimeRolePlan` compare-and-swaps that exact reservation Reserved→Consumed and mints the
  `RolePlan`, `RolePlanDigestBinding`, `VerifiedServicePlacement`, and the sole initial cursor — `Prereq`
  — together inside one rank-2 continuation. `Load` survives only as a descriptive label, exactly as this
  sprint's deliverable states.
- **The admission is genuinely one-use.** The key binds the signed parent plan digest, frame, immutable
  rollout revision, and the **measured** instance, so a real restart (a different container restart
  count, or a fresh host invocation nonce) gets its own admission while a replayed activation does not.
  An existing record is `RoleAdmissionRecoveryRequired` carrying the predecessor's own bytes — never
  silently overwritten — and a lost write is its own `RoleAdmissionUnknown` rather than an error. A
  second `withRuntimeRolePlan` against the same reservation is `RoleAdmissionAlreadyConsumed`, because
  the compare-and-swap names the exact version the reservation was observed at.
- **The lease requirement is derived, not chosen.** `RoleEffect` is a closed vocabulary
  (`network-listen`, `network-connect`, `durable-store`, `process`); an effect the signed ceiling names
  but core does not recognise is `RoleEffectUnsupported` rather than assumed harmless. `durable-store`
  and `process` are the exclusive ones, and a draft that declares an exclusive resource under a ceiling
  permitting none is refused at verification — so the two cannot disagree silently and a mutating role
  cannot appear on the no-lease branch.
- **The exclusive branch takes a real kernel lock.** When the ceiling requires a generation lease, the
  whole Acquire→Drain bracket runs inside `Protected.withRunLiveness` — the § EE clause-1 primitive the
  OS releases on process death. A live exclusive peer is refused **before** its first acquisition, so its
  refusal legitimately carries `VerifiedNoRoleResources`; a dead predecessor never blocks, because the
  kernel already released the lock.
- **Failure branches carry their only legal successor.** `exitWithNoRoleResources` is the sole route to
  an empty rollback set and it *demands* the `VerifiedNoRoleResources` proof, which only the engine can
  produce and only where nothing was acquired. Every other turn-around — a failed acquisition, an
  **unknown** acquisition, a readiness failure, a serve failure, a catchable shutdown — reaches Exit only
  through Drain, and Drain carries every owned resource and every unknown one. An unknown acquisition is
  retained rather than dropped, and it makes the exit unclean.
- **Nothing escapes to project code.** `RoleCursor`, `RolePlan`, `VerifiedServicePlacement`,
  `ReservedRoleAdmission`, `VerifiedRolePlanDraft`, `ReadyRoleHandles`, `RolePlanDigestBinding`, and
  `VerifiedNoRoleResources` all hide their constructors. The engine's callbacks are per-resource or take
  only `ReadyRoleHandles`, whose names come solely from resources Acquire created and Ready probed — so
  there is no serve-time bind/spawn hatch. The one public result is `RoleExitReport`. Because `mask`
  hands back a rank-2 `restore`, the phase functions thread it through a `Restore` newtype rather than
  letting it monomorphise, so each project callback is individually restored and a callback that throws
  is converted to that callback's typed branch instead of escaping between Acquire and Drain.

Validation (2026-07-30): `cabal build all --ghc-options=-Werror` and `cabal test all
--ghc-options=-Werror` pass from `core/` at **769** (up from 744). `RoleLifecycleSpec` contributes **27**
cases against a real protected store, real Ed25519 grants signed by a real root invocation, and a real
kernel lock — covering the draft rules and its length-prefixed digest, all four verification refusals,
reserve/recovery-owed/consume-once, both lease requirements, and every engine branch above including the
live-exclusive-peer refusal. The new `ForgeRoleCursor.hs` compile-fail fixture proves all nine of those
constructors are unreachable; `CompileFailSpec` now runs **31** fixtures. The demo workspace passes its
own **110** tests plus the embedded **769**-test core suite under the same gate, and the Python suite
passes **231**.

**Still open (this sprint): the `service run` call-site adoption — `Blocked by` Sprint 16.6.**

This is a structural dependency, not a scheduling preference. `service run` can require the activation
package only if something in production can *produce* one, and today nothing can: a signed
`ActivationManifest` needs an `ActivationBroker`, which `withActivationBroker` mints only from a
`RootInvocationAuthority`. Repository search finds `Authority.withVerifiedRootInvocation` has **no
production consumer** — `project up` still uses the class-membership gate. Sprint 15.9's own remaining
work assigns that replacement ("replace the class-membership-only `project up` gate with
`authorizeProjectCommand` at the command layer") to Sprint 16.6. Until it lands there is no live root
authority at `deploy-chart` time to sign the pod-template revision's manifest, so gating `service run` on
one would make every runtime role unstartable rather than more authorized.

What remains here, once 16.6 supplies the root-authorized `project up`:

- have the `deploy-chart` step sign one `ActivationManifest` per pod-template revision and install the
  immutable digest-addressed ConfigMap, Secret, and manifest objects (the Secret being the sole
  secret-bearing object), with the host-daemon lane switching one revision directory/pointer and minting
  a fresh invocation nonce;
- have `service run` measure its own binary, mounted role-wire, and private-bundle digests plus its
  instance identity, verify the activation against the independently installed project key, and enter the
  chain above instead of calling the selected action directly;
- pass the registry-selected action to the engine as `engineServe`, which Sprint 18.6 then narrows to the
  effect-indexed `ServiceProgram`.

### Sprint 14.7: Scope-indexed endpoints and registry blob delivery [Done]

**Status**: Done
**Blocked by**: None (Sprints 9.10 and 19.8 are complete)
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Network.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/test/RegistryPlanSpec.hs`
**Docs to update**: `documents/architecture/network_reachability.md`,
`documents/architecture/composition_methodology.md`,
`documents/engineering/derived_project_standards.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make it impossible for a finalized operation plan to redirect a client to a backend outside that
client's verified network scope.

#### Deliverables

- Add closed reachability kinds and opaque scope-indexed endpoint, client, and exposure values; no raw
  hostname, `localhost`, or `.svc` convention may mint reachability authority.
- Add proof-gated `BlobDelivery`, with no `ReachableFrom HostLocal ClusterOnly`, and expose only
  topology-specific smart constructors for opaque `RegistryPlan`.
- Derive Distribution redirect configuration and every workload projection from the finalized plan;
  remove raw redirect booleans and independently assembled registry/store endpoint fields.
- Integrate the route with Sprint 9.10's identity-bound operation preconditions so only the exact
  client/exposure/store/revision observation can yield `ReadyBlobRoute`.

#### Validation

- Compile-fail tests reject host-local→cluster-only redirects, endpoint-kind substitution, plan mixing,
  raw redirect selection, and reuse of a route witness across a replacement revision.
- Constructor/property tests cover every supported reachability pair; golden tests prove that delivery
  strategy uniquely determines rendered redirect configuration.
- Negative adapter tests prove `/v2/` readiness cannot prepare a push when blob `HEAD` yields an
  out-of-scope `307`.

#### Remaining Work

**Delivered 2026-07-29 — the generic algebra.**

- `HostBootstrap.Network` makes the network scope a **type index**. `Endpoint scope`,
  `NetworkClient scope`, and `Exposure scope` are opaque and minted only by scope-specific smart
  constructors that reject a scheme, a path, whitespace, or an empty authority, so no raw hostname,
  `localhost`, or `.svc` convention can mint reachability. `Reachability client endpoint` is a closed
  GADT enumerating every legal pair — and it deliberately has **no**
  `Reachability 'HostLocal 'ClusterOnly` constructor. `loopbackExposure` fixes the authority to
  `127.0.0.1`, so a wildcard publication of a project-local service is unrepresentable.
- `HostBootstrap.RegistryPlan` carries no redirect boolean. `BlobDelivery client` has a proxying
  constructor that needs no proof and a redirecting constructor that **takes** the `Reachability`
  witness, so a host-local client and a cluster-only store admit no redirecting delivery at all.
  `RegistryPlan client store` is opaque with topology-specific constructors only
  (`hostServedRegistryPlan`, `inClusterRegistryPlan`), so a registry endpoint and a store endpoint
  cannot be assembled independently and paired by convention.
- `renderStorageRedirect` **derives** the Distribution `storage.redirect` stanza from the delivery: a
  proxying plan renders `disable: true`, a redirecting plan renders nothing. Because the delivery is the
  only input, the rendered configuration and the reachability proof cannot disagree.
- `settleBlobRoute` mints `ReadyBlobRoute client store` only from an observation that is a real blob
  request (an `ApiVersionProbe` — `/v2/` answering — is refused outright as
  `BlobRouteNotABlobProbe`), on the plan's current revision, dialling the plan's exact published
  exposure port, with an outcome matching the planned delivery. A replacement revision yields
  `BlobRouteStaleRevision`, so a witness cannot be reused across one.

Validation: `RegistryPlanSpec` runs **22** cases — the reachability relation enumerated over all nine
scope pairs and pinned to exactly four, authority rejection, loopback fixing, both plan topologies, the
golden delivery→rendering pairing, and every route-refusal branch including the live defect (a proxying
plan observed issuing a `307` to `minio.default.svc:9000`). Four compile-fail fixtures reject the
host-local→cluster-only redirect, endpoint-scope substitution, a raw `RegistryPlan`, and a forged
`ReadyBlobRoute`. Core gate **587/587**, demo **106**, Python **227**, all under `-Werror`.

**Still open:** the demo migration. `demo/src/HostBootstrapDemo/Commands.hs` still assembles
`minioClusterEndpoint`, `registryEndpoint`, and `registryConfigYaml` independently, and that
`config.yml` carries **no** `storage.redirect` stanza at all — so the running registry keeps
Distribution's redirecting default while a host client pushes to it. Migrating those call sites onto this
plan, and proving the route live, is Sprint 13.20's work; this sprint deliberately added no temporary raw
redirect flag for it to consume.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` - the operation algebra, the self-reference lift,
  and the deploy ≡ business-logic unification, including the single-representation doctrine — the
  project-owned `[Step]` lifecycle plan is the representation, and the harness drives it without a
  parallel deployment graph (cross-references standards § W, § T, § U).
- `documents/architecture/network_reachability.md` - scope-indexed endpoints, proof-gated blob
  delivery, finalized registry plans, and route-specific readiness (created; implementation open).

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` - the shape cookbook (created).
- `documents/engineering/authoring_project_binaries.md` - the authoring how-to (created).
- `documents/engineering/registry_credentials.md` - forwarding the host Docker Hub login down the lift to
  authenticate nested pulls, modelled (`HostBootstrap.Registry`) so the credential is excluded from
  Dhall, durable project/image state, and `argv`, with bounded transient stdin/environment/file effects
  documented honestly (created).

**Cross-references to add:**
- `documents/README.md` indexes the three new docs; `system-components.md` carries the
  `HostBootstrap.Lift` row; `development_plan_standards.md` § U is rewritten to the n-level lift.
