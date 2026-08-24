# Composition Patterns: A Cookbook Of Chain Shapes And Step Kinds

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](../architecture/composition_methodology.md), [wsl2](wsl2.md)

> **Purpose**: A cookbook of reusable composition shapes — frame topologies, step kinds, and
> business-logic shapes — so a downstream author can recognize their workflow and express it as the
> ordered step contribution finalized into the `StepPlan` a self-referential project binary interprets.

## TL;DR

- A workflow is an opaque validated **`StepPlan`** of `Step`s (what each step does) interpreted across a **frame topology**
  (where each step runs — the self-reference lift stack). The two axes are orthogonal; this cookbook
  catalogues both.
- **The plan is the project.** A consumer contributes one ordered step fragment from root parameters;
  finalization produces the `StepPlan` from which exact plan admission derives the current-frame
  execution and declared descent. The target `project up` interpreter repeats that operation across
  authenticated child entries. The shapes below are generic; any consumer assembles its specific
  fragment from them.
- The foundational model is [composition_methodology](../architecture/composition_methodology.md) (the
  canonical home — defer to it, do not re-derive it); the layering of who contributes which step kind
  is [library_hierarchy](../architecture/library_hierarchy.md).
- A third group, **business-logic shapes**, shows the same algebra composing runtime logic (roles over
  durable external stores), not just deployment.

## Frame Topologies

Each topology is a lift stack of **frames** (outermost-first). In the complete model, a binary crosses
each boundary by handing off an authenticated `pb project up` entry into the next frame (the selected
VM provider for a VM, `docker run` for a container). The chain is one flat `[Step]`, and each pb owns
its own segment. The current public Chain executes one authorized current-frame segment and derives the
declared child boundary; authenticated child admission and cross-frame continuation remain with the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

1. **One-shot container lift** — `host → docker run <project-container> pb project up`. Run a tool the
   host lacks (a cloud CLI, `helm`) inside the project container. The atom every other shape builds on.
2. **Pristine-host VM bootstrap** — `host → VM (re-establish the binary host-native) → container →
   deploy`. The worked [demo](../operations/demo_runbook.md): the no-copy-out rebuild-in-context case.
   Its chain is a **single** ordered `[Step]` — deploy-VM (ensure the VM provider — Lima on Apple Silicon,
   Incus on Linux, WSL2 on Windows) → deploy-VM (launch/start the provider VM; sizing is
   creation-time for Lima/Incus and utility-VM-global for WSL CPU/memory) →
   build-pb (the pristine-host bootstrap: build the binary host-native, then the project image, in the
   VM) → context-init announcing frame anchor in the VM → deploy-kind → deploy-minio → deploy-registry → push-image →
   deploy-chart → expose-port → accelerator-daemon placement —
   that stands up a live, persistent stack ending at a web service. See
   [single representation](#single-representation-the-chain-is-the-representation).
3. **Host → managed cloud cluster** — build the container, then a container-frame step uses a cloud CLI
   to provision a managed Kubernetes cluster against an external state backend, then a later step runs
   `helm` into it. No VM; the cloud is the substrate.
4. **Local cluster via a host service manager** — bring a cluster up as a host `systemd`/`launchd`
   service (e.g. `rke2`/`k3s`), deploy into it, optionally layer cloud-validation stacks via an
   in-cluster state store.
5. **Phased, registry-first cluster bring-up** — within a cluster frame, an ordering shape: stand up
   storage + database + **registry foundation first**, mirror images through the in-cluster
   registry, then platform services, then the workload chart.
6. **Host-native daemon bridged to an in-cluster coordinator** — the binary also runs as a long-lived
   host daemon (singleton via lifecycle ownership directories plus strict PID identity) that connects to
   an in-cluster coordinator, used when a capability is reachable only on the host. The accelerator demo is
   the small implemented instance:
   Apple Silicon and Windows GPU daemons run host-native, connect to the web service over its exact
   runtime-resolved loopback exposure, exchange CBOR over WebSocket, and forward work to a generated native worker. See
   [accelerator_daemon](accelerator_daemon.md).
7. **Headless host build for platform-locked artifacts** — a generic consumer may build a
   platform-locked artifact on the bare host (no build VM) and stage it into a cluster. This is distinct
   from pattern 6's accelerator: its Windows daemon uses the same `ensure cudawin` toolchain but builds
   **and runs** the worker on the host rather than staging it into WSL2/kind.
   See [cuda](../languages/cuda.md) and [ensure_reconcilers](ensure_reconcilers.md).
8. **GPU cluster variant** — substrate-select a GPU cluster (device-plugin / GPU-aware kind /
   `RuntimeClass`) and pin accelerator-owning pods; the same chains with a GPU node. For the demo's
   Linux GPU accelerator lane this means skipping the Incus VM and launching an `nvkind` cluster directly
   on the host through the project container, then running the CUDA accelerator daemon pod from the CUDA
   hostbootstrap base image.

Optional structural variation (skip the VM → straight to Docker) is a root-`.dhall` flag, so the chain
stays a pure function of root parameters.

## The Chain And Its Target Recursive Interpreter

`StepPlan` is the single forward ordering. Exact plan admission derives its topology and current-frame
projections; the public Chain interprets only the authorized current-frame segment. The target recursive
(`fractal`) `project up` interpreter authenticates a child entry and repeats that operation at each
declared boundary. The canonical home for this doctrine is
[composition_methodology § The Self-Reference Lift](../architecture/composition_methodology.md#the-recursive-project-up-interpreter);
the cookbook summary:

- **Opaque validated `StepPlan`.** The forward source begins as ordered additive fragments computed from
  root parameters. `mkStepPlan` rejects empty, duplicate, conflicting, post-handoff-invalid, and
  non-contiguous `A/B/A` sequences; `--dry-run` renders every accepted plan in exact source order.
- **Fractal descent (target).** Each `project up` frame boundary is the same move: *provision the frame
  → build/install the pb in it → authenticate and hand off `pb project up`*. The current interpreter
  runs the local segment and derives the next frame and lift context, but a nested lifecycle entry fails
  closed until the child-admission protocol is implemented. Reconcilers attempt convergence, but typed
  idempotent outcomes are not yet universal.
- **The Python bootstrapper is the metal-frame precursor** to that pattern — provision the metal frame,
  build/install the pb, hand off — with two caveats the cookbook reuses: the *build* step is
  parent-orchestrated (the child pb does not exist yet), and the container frame *skips* the build
  (`docker run img project up`). Proof-complete continuation through the Haskell-owned frame stack is
  still target work.
- **`.dhall` is parameters + context + witness, never the shape.** Each pb reads the sibling
  `<project>.dhall`, verifies it occupies the frame the `.dhall` describes, and fails fast on a wrong
  handoff before the current frame's chain effects. Outer-frame provider/preparation effects may already
  have occurred (see [dhall_topology](dhall_topology.md)).

The active demo forward projector builds a deterministic child-local full graph rather than copying the
parent plan. Substrate detection must run before sibling-config decode, but only the root selector consults
it. Nested Incus uses the Linux-CPU graph with its in-cluster daemon; nested Lima/WSL2 uses the common
VM-backed graph without the root-only host hook; the direct edge uses the direct graph. VM/container payloads
share one exact newline-terminated renderer. The direct preview carries its child-derived descriptor and
durable path through the existing `DemoDurableBind` lineage, not a reused parent mount or a fabricated
`CanonicalProjectRoot`.

## Step Kinds

Orthogonal to topology: each entry in the chain is a `Step` of one kind. The **Step algebra is the
reuse unit**. Core ships the host-management step kinds; the project contributes its own kinds into the
same `[Step]`, and host and workload steps interleave freely. This is the workload-extension seam.

| Origin | Step kinds (examples) |
|---|---|
| Core (host-management) | `deploy-vm`, optional `ensure-<tool>` row, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`, `expose-port`, `post-handoff-<name>` |
| Project (workload) | `deploy-minio`, `deploy-registry`, `push-image`, accelerator placement, … contributed by the consumer |

The current demo does not use `ensureStep`; it calls `runEnsure` inside composite
provider/build/accelerator actions. Its `context-init` action body is also a no-op announcement: VM
config delivery is inside the composite bootstrap, container projection/delivery is in the descent that
same `context-init` step declares plus the handoff, and service projections are in deployment actions. The target plan gives each
effect an explicit operation identity and prevents those labels from drifting from the work.

The canonical taxonomy of step semantics — converge / context-lift / one-shot action / control-loop /
run-to-completion, plus each kind's plan/apply, retry behaviour, and L0/L1/L2 layer — lives in
[composition_methodology](../architecture/composition_methodology.md); this cookbook composes steps of
those kinds across the topologies above. Which layer contributes which kind is
[library_hierarchy](../architecture/library_hierarchy.md).

## Single Representation: The Chain Is The Representation

One operation must have one representation. Forward ordering is the `[Step]` returned by
`chain`; exact admission creates an opaque `ProjectPlan scope specDigest planId configId cfg`, whose
topology and current-frame forward and reverse projections come from that same sequence. Each descent
is declared by a plan node (`descendsVia`), and each acquiring node declares the effect that releases it
(`reversedBy`). Current verbs consume those exact current-frame projections. The recursive interpreter
authenticates entry at each child, traverses forward frame by frame, and drives child-first reverse work
from receipt-bound ownership. Descriptive topology never substitutes for command authority. The canonical home is
[composition_methodology § Single Representation](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation)
(and [development_plan_standards § W](../../DEVELOPMENT_PLAN/development_plan_standards.md)); the
summary for shape 2:

- The shape-2 plan declares one persistent-stack descent: the metal segment provisions the VM and
  rebuilds the binary + project image in it, the in-VM segment reaches its `context-init` anchor and
  declares the project-container handoff, and the in-container segment runs deploy-kind → deploy-minio
  → deploy-registry → push-image → deploy-chart → expose-port and places the accelerator daemon. The
  target authenticated interpreter reaches the live web service through those segments; the current
  public boundary executes only the admitted current-frame segment.
- The standardized harness (`HostBootstrap.Harness`: `runMatrix` + `Seams`) is a **separate** test
  surface. For each generated run it constructs and retains an exact `ProjectPlan (Harness projectId
  runId) ...`, drives the Cabal-private fixed root-Up entry through the recursive Chain and exact reverse
  boundary, and keeps assertion logic outside lifecycle authority. A restart-spanning case requests the
  engine-owned settled reverse, protected invocation rotation, exact plan rebind, second forward, and one-row
  before/after assertion merge.

## Business-Logic Composition Shapes

The same algebra composes runtime logic. Each is an extension (L1/L2 via the extension-stream merge) that
relies only on an L0 affordance (the role-lifecycle skeleton, Dhall config/schema-gen, the extension
streams) — so L0 hosts it without modification.

For a runtime role, verify the signed activation and project-owned non-empty role draft before entering the
protected admission. Treat `RoleAdmissionReserved` as the only ordinary open input,
`RoleAdmissionOpenUnknown` as a lost-acknowledgement signal for `resumeRuntimeRolePlanOpen`, and every
contradictory predecessor as recovery work rather than a new run. Supply total callback outcomes. In
particular, `engineRelease` must idempotently reprobe-and-release a resource whose acquisition result was
unknown; returning `Released` is the proof that resolves it. The core runner consumes the Prereq cursor once,
forces each callback result inside its interruption guard, drives every successor internally, and always
attempts all Drain releases after any possible acquisition.

- **Message-bus + object-store workflow** — a stateless **role** consumes a request topic, dispatches
  to a consumer engine, publishes a result topic; static artifacts ride the object store by reference; a
  hydrator role concentrates WAN egress; batching/scheduler policy is the scaling composition point; a
  lifecycle reconciler realizes declared topic/bucket lifecycle. The workflow is a declared topology
  (request-response / fan-out-in / batched / pipeline / stream) as data.
- **Webservice / SPA** — a serving role whose API and UI are described as typed Dhall (config-gen + the
  schema-gen registry stream). The in-tree demo is the minimal instance: it contributes its SPA as a typed
  Dhall artifact (`demoWebApp` — title + tabs + each tab's API binding, reflected through the registry and
  renderable with `context render --artifact demoWebApp`), mirroring the tabs the Halogen app renders.
  Generating the SPA's source *from* that spec (rather than mirroring a hand-written app) is the aspirational
  extension — an arbitrary-SPA Dhall DSL.

## Cross-Cutting Concerns

Reused across shapes and step kinds:

- **Budget propagation at every boundary (target)** via one pure provider-exact wall spec/effective
  budget, a proved pre-effect partition, exact per-frame slices, and journaled same-spec
  reservation→observed-live-authority transition. Current VM creation and kind/nvkind node paths have partial caps, but direct Colima
  and the outer direct-Linux-GPU build/container effects are not uniformly capped, existing provider
  walls are not uniformly reconciled, and child service configs do not receive the computed slice (see
  [applied_cordon](applied_cordon.md) and [resource_budgeting](resource_budgeting.md)).
- **Teardown discipline (target)** — descend while each child is reachable, then stop/delete on ascent;
  require verified ownership receipts, preserve durable data, aggregate independent failures, and return
  explicit idempotent outcomes. Current commands consume the exact plan's current-frame reverse
  projection but do not authenticate recursive child traversal or bind every release to ownership
  receipts; see
  [cluster_lifecycle](cluster_lifecycle.md) and
  [lifecycle state model](../architecture/lifecycle_state_model.md).
- **Plan→Apply** — `project up --dry-run` renders `chain cfg` (the planned step sequence) before
  the mutating apply.
- **Substrate multiplexing** — the same pure chain parameterized over `(model × substrate)` under one
  control-plane contract.
- **The test surface drives the deploy** — `test run all` runs the standardized harness
  (`runMatrix` over the project's cases). Each generated run retains an exact Harness-scoped plan and
  drives the hidden fixed root-Up entry into the lower current-frame Chain and the exact reverse boundary;
  it does not construct a second per-case deployment graph. The harness stays frame-agnostic and may lift a case into the
  cluster as a Job (a finite-job operation); see
  [single representation](#single-representation-the-chain-is-the-representation) and
  [harness_workflow](../architecture/harness_workflow.md).
- **Real accelerator tests** — a substrate-specific daemon path is closed only by integration tests that
  build the generated worker in its real lane and by browser e2e tests that drive the UI add workflow
  through CBOR WebSocket to that worker. Unit tests for protocol/codegen are necessary but cannot replace
  the real build/run gates.

## Current Status

The **plan surface** this cookbook describes is the running system: the core command tree is exactly
`project`, `test`, `service`, `context`, and `check-code`, and the demo's deploy is the pure value
`demoChainFor :: Substrate -> CanonicalProjectRoot scope rootId -> ProjectConfig scope -> [Step]`
(`demo/src/HostBootstrapDemo/Commands.hs`), whose result is accepted only through `addSteps` and
`finalizeProjectSpec`; its VM-backed branch declares shape 2 as one ordered plan ending at a live web
service. Execution across its declared frames uses authenticated child admission and recursive traversal. The lift
primitive uses provider-backed folds for Incus and Lima (and WSL2 on Windows, with authenticated recursive
closure owned by the [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) — see
[wsl2](wsl2.md)) and a topology-aware binary-context gate. The
reconcilers (`clusterUp`, `clusterCreate`, `deployChart`, `clusterDown`, `clusterDelete`) live in
`HostBootstrap.Cluster.Lifecycle`, invoked by the chain steps and the lifecycle command.

The opaque `StepPlan`, admitted `ProjectPlan`, core Step algebra, and workload-contributed step kinds
compose one exact forward description. The current public Chain executes the authorized current-frame
segment and derives its declared descent; nested lifecycle entry fails closed pending authenticated
child admission and proof-complete traversal. The complete interpreter is intended to carry the Incus/Linux
plan through to a cordoned kind cluster, the in-cluster registry, the project image pushed to that
registry, and the web chart pod serving through its runtime-resolved loopback endpoint. Current `project down`/`project destroy`
consume the verb's exact current-frame reverse projection and must not be described as fractal teardown. The
demo's status is tracked in
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) and the composition phases of the
development plan.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — the canonical foundational
  model these shapes instantiate.
- [authoring_project_binaries](authoring_project_binaries.md) — how to author a `chain` from these
  shapes (its step actions, test suite, and Dhall vocabulary).
- [library_hierarchy](../architecture/library_hierarchy.md) — the extension-stream merge that adds step
  kinds.
- [dhall_topology](dhall_topology.md) — the topology frames declared by the plan and consumed by the
  target recursive interpreter.
