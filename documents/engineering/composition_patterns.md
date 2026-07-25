# Composition Patterns: A Cookbook Of Chain Shapes And Step Kinds

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](../architecture/composition_methodology.md), [wsl2](wsl2.md)

> **Purpose**: A cookbook of reusable composition shapes — frame topologies, step kinds, and
> business-logic shapes — so a downstream author can recognize their workflow and express it as the
> `chain :: cfg -> [Step]` value a self-referential project binary interprets.

## TL;DR

- A workflow is a **chain** of `Step`s (what each step does) interpreted across a **frame topology**
  (where each step runs — the self-reference lift stack). The two axes are orthogonal; this cookbook
  catalogues both.
- **The chain is the project.** A consumer's identity is the single ordered `[Step]` value its
  `chain` function returns from root parameters; `project up` is the recursive interpreter that walks
  it. The shapes below are generic; any consumer assembles its specific chain from them.
- The foundational model is [composition_methodology](../architecture/composition_methodology.md) (the
  canonical home — defer to it, do not re-derive it); the layering of who contributes which step kind
  is [library_hierarchy](../architecture/library_hierarchy.md).
- A third group, **business-logic shapes**, shows the same algebra composing runtime logic (roles over
  durable external stores), not just deployment.

## Frame Topologies

Each topology is a lift stack of **frames** (outermost-first); a binary crosses each boundary by
handing off `pb project up` into the next frame (the selected VM provider for a VM, `docker run` for a
container). The chain is one flat `[Step]`; the interpreter descends frame-by-frame, and each pb owns
its own segment.

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
   Apple Silicon and Windows GPU daemons run host-native, connect to the web service over a local-only
   NodePort, exchange CBOR over WebSocket, and forward work to a generated native worker. See
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

## The Chain And Its Recursive Interpreter

The chain is the current single forward ordering and `project up` is its recursive (fractal)
interpreter. Current frame transport and teardown remain separate inputs; the target opaque plan derives
all three views together. The canonical home for this doctrine is
[composition_methodology § The Self-Reference Lift](../architecture/composition_methodology.md#the-recursive-project-up-interpreter);
the cookbook summary:

- **`chain :: cfg -> [Step]`.** The current forward source is one flat list computed from root
  parameters. `--dry-run` renders source order, but public constructors do not enforce a non-empty,
  contiguous frame sequence: `A/B/A` is grouped by first frame appearance and executes as `A/A/B`.
- **Fractal descent.** Each `project up` frame boundary is the same move: *provision the frame → build/install the
  pb in it → hand off `pb project up`*. The interpreter runs the current frame's steps, then re-invokes
  the binary in the next frame, which interprets its own segment of the same chain. Reconcilers attempt
  convergence, but typed idempotent outcomes are not yet universal.
- **The Python bootstrapper is the metal-frame instance** of that exact pattern — provision the metal
  frame, build/install the pb, hand off — with two caveats the cookbook reuses: the *build* step is
  parent-orchestrated (the child pb does not exist yet), and the container frame *skips* the build
  (`docker run img project up`). Recursion bottoms out at the container pb, which runs kind/registry/web
  as `kubectl`/`helm` leaves.
- **`.dhall` is parameters + context + witness, never the shape.** Each pb reads the sibling
  `<project>.dhall`, verifies it occupies the frame the `.dhall` describes, and fails fast on a wrong
  handoff before the current frame's chain effects. Outer-frame provider/preparation effects may already
  have occurred (see [dhall_topology](dhall_topology.md)).

## Step Kinds

Orthogonal to topology: each entry in the chain is a `Step` of one kind. The **Step algebra is the
reuse unit**. Core ships the host-management step kinds; the project contributes its own kinds into the
same `[Step]`, and host and workload steps interleave freely. This is the workload-extension seam.

| Origin | Step kinds (examples) |
|---|---|
| Core (host-management) | `deploy-vm`, optional `ensure-<tool>` row, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`, `expose-port`, `post-handoff-<name>` |
| Project (workload) | `deploy-minio`, `deploy-registry`, `push-image`, accelerator placement, … contributed by the consumer |

The current demo does not use `ensureStep`; it calls `runEnsure` inside composite
provider/build/accelerator actions. Its `context-init` action is also a no-op announcer: VM config
delivery is inside the composite bootstrap, container projection/delivery is in
`psFrameContext`/handoff, and service projections are in deployment actions. The target plan gives each
effect an explicit operation identity and prevents those labels from drifting from the work.

The canonical taxonomy of step semantics — converge / context-lift / one-shot action / control-loop /
run-to-completion, plus each kind's plan/apply, retry behaviour, and L0/L1/L2 layer — lives in
[composition_methodology](../architecture/composition_methodology.md); this cookbook composes steps of
those kinds across the topologies above. Which layer contributes which kind is
[library_hierarchy](../architecture/library_hierarchy.md).

## Single Representation: The Chain Is The Representation

One operation must have one representation. Current forward ordering is the `[Step]` returned by
`chain`, and `project up` is its interpreter, but independently supplied `psFrameContext` and
`psTeardown` mean the complete lifecycle does not yet meet that rule. The target opaque
`ProjectPlan scope specDigest planId configId cfg`
accepts one non-empty validated step sequence, derives topology, and derives child-first reverse work
from the receipts acquired during forward interpretation. The canonical home is
[composition_methodology § Single Representation](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation)
(and [development_plan_standards § W](../../DEVELOPMENT_PLAN/development_plan_standards.md)); the
summary for shape 2:

- The shape-2 chain stands up a persistent stack as one descent: `project up` interprets it across the
  composed frame stack — the metal frame provisions the VM and rebuilds the binary + project image in
  it, the in-VM frame reaches an announcing `context-init` anchor and hands off the
  `psFrameContext`-derived project-container config, and the in-container frame
  runs deploy-kind → deploy-minio → deploy-registry → push-image → deploy-chart → expose-port and places
  the accelerator daemon. The chain ends at a live web service.
- The standardized harness (`HostBootstrap.Harness`: `runMatrix` + `Seams`) is a **separate** test
  surface, frame-agnostic — it runs its reconcilers (e.g. `clusterUp`) as `HostConfig -> IO ()`
  with no second bring-up path inside it. `test run all` drives the real `project up`.
- The harness, per distinct test config, writes a `<project>.dhall`, runs `project up`, asserts the live
  stack in-frame, and invokes `project destroy` even if a body fails. The demo currently resolves that
  plan as Production/`.data`; target `Harness projectId runId` isolation is open. It reuses the same chain `project up`
  stands up, so there is no
  separate per-case bring-up. Thus the harness does not add another forward graph, even though the
  current lifecycle still has the independent frame/teardown seams described above.

## Business-Logic Composition Shapes

The same algebra composes runtime logic. Each is an extension (L1/L2 via the extension-stream merge) that
relies only on an L0 affordance (the role-lifecycle skeleton, Dhall config/schema-gen, the extension
streams) — so L0 hosts it without modification.

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
  explicit idempotent outcomes. Current commands perform current-frame cleanup plus a hook instead; see
  [cluster_lifecycle](cluster_lifecycle.md) and
  [lifecycle state model](../architecture/lifecycle_state_model.md).
- **Plan→Apply** — `project up --dry-run` renders `chain cfg` (the planned step sequence) before
  the mutating apply.
- **Substrate multiplexing** — the same pure chain parameterized over `(model × substrate)` under one
  control-plane contract.
- **The test surface drives the deploy** — `test run all` runs the standardized harness
  (`runMatrix` over the project's cases), which per distinct test config drives the real `project up`,
  asserts the live stack, and tears it down with `project destroy`. It reuses the chain rather than
  standing up a separate per-case cluster. The harness stays frame-agnostic and may lift a
  case into the cluster as a Job (a finite-job operation); see
  [single representation](#single-representation-the-chain-is-the-representation) and
  [harness_workflow](../architecture/harness_workflow.md).
- **Real accelerator tests** — a substrate-specific daemon path is closed only by integration tests that
  build the generated worker in its real lane and by browser e2e tests that drive the UI add workflow
  through CBOR WebSocket to that worker. Unit tests for protocol/codegen are necessary but cannot replace
  the real build/run gates.

## Current Status

The **chain surface** this cookbook describes is the running system: the core command tree is exactly
`project`, `test`, `service`, `context`, and `check-code`, and the demo's deploy is the pure value
`demoChainFor :: Substrate -> ProjectConfig -> [Step]` (`demo/src/HostBootstrapDemo/Commands.hs`), whose
VM-backed branch realizes shape 2 as one ordered chain that stands up the persistent stack and ends at a
live web service. The lift
primitive uses provider-backed folds for Incus and Lima (and WSL2 on Windows, with full lifecycle closure
still tracked in phase 11 — see
[wsl2](wsl2.md)) and a topology-aware binary-context gate. The
reconcilers (`clusterUp`, `clusterCreate`, `deployChart`, `clusterDown`, `clusterDelete`) live in
`HostBootstrap.Cluster.Lifecycle`, invoked by the chain steps and the lifecycle command.

The `chain :: cfg -> [Step]` value, the recursive `project up` interpreter, the core Step
algebra, and workload-contributed step kinds compose the current forward path end-to-end: a single
`project up` on Incus/Linux stands up the live persistent stack — a
cordoned kind cluster, the in-cluster registry, the project image pushed to that registry, and
the web chart pod serving `localhost:30080`. Current `project down`/`project destroy` perform owning
current-frame cluster cleanup plus a project hook; they do not recursively traverse the chain and must
not be described as fractal teardown. The
demo's status is tracked in
[Phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md) and the composition phases of the
development plan.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — the canonical foundational
  model these shapes instantiate.
- [authoring_project_binaries](authoring_project_binaries.md) — how to author a `chain` from these
  shapes (its step actions, test suite, and Dhall vocabulary).
- [library_hierarchy](../architecture/library_hierarchy.md) — the extension-stream merge that adds step
  kinds.
- [dhall_topology](dhall_topology.md) — the topology frames the recursive chain descends through.
