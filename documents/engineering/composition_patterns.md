# Composition Patterns: A Cookbook Of Chain Shapes And Step Kinds

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](../architecture/composition_methodology.md)

> **Purpose**: A cookbook of reusable composition shapes — frame topologies, step kinds, and
> business-logic shapes — so a downstream author can recognize their workflow and express it as the
> `chain :: ProjectConfig -> [Step]` value a self-referential project binary interprets.

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
   Its chain is a **single** ordered `[Step]` — deploy-VM (Lima on Apple Silicon, Incus on Linux) →
   build-pb (the pristine-host bootstrap: build the binary host-native, then the project image, in the
   VM) → context-init in the VM → deploy-kind → deploy-harbor → push-image → deploy-chart → expose-port —
   that stands up a live, persistent stack ending at a web service. See
   [single representation](#single-representation-the-chain-is-the-representation).
3. **Host → managed cloud cluster** — build the container, then a container-frame step uses a cloud CLI
   to provision a managed Kubernetes cluster against an external state backend, then a later step runs
   `helm` into it. No VM; the cloud is the substrate.
4. **Local cluster via a host service manager** — bring a cluster up as a host `systemd`/`launchd`
   service (e.g. `rke2`/`k3s`), deploy into it, optionally layer cloud-validation stacks via an
   in-cluster state store.
5. **Phased, registry-first cluster bring-up** — within a cluster frame, an ordering shape: stand up
   storage + database + **registry foundation first**, mirror all images through the in-cluster
   registry, then platform services, then the workload chart.
6. **Host-native daemon bridged to an in-cluster coordinator** — the binary also runs as a long-lived
   host daemon (singleton via a file lock) an in-cluster workload reaches over a message bus, used when
   a capability (an accelerator) is reachable only on the host. The `HostDaemon`
   [run-model](../architecture/run_models.md).
7. **Build-only VM for platform-locked artifacts** — lift a *build* into an ephemeral VM to produce a
   platform-specific artifact, copy it out, never run the workload in the VM (the `ensure tart` shape).
8. **GPU cluster variant** — substrate-select a GPU cluster (device-plugin / GPU-aware kind /
   `RuntimeClass`) and pin accelerator-owning pods; the same chains with a GPU node.

Optional structural variation (skip the VM → straight to Docker) is a root-`.dhall` flag, so the chain
stays a pure function of root parameters.

## The Chain And Its Recursive Interpreter

The chain is the single representation of the project; `project up` is its recursive (fractal)
interpreter. The canonical home for this doctrine is
[composition_methodology § The Self-Reference Lift](../architecture/composition_methodology.md#the-recursive-project-up-interpreter);
the cookbook summary:

- **`chain :: ProjectConfig -> [Step]`.** The whole project topology is one flat, ordered list of steps,
  computed purely from the root parameters. `--dry-run` renders exactly this value.
- **Fractal descent.** Each frame boundary is the same move: *provision the frame → build/install the
  pb in it → hand off `pb project up`*. The interpreter runs the current frame's steps, then re-invokes
  the binary in the next frame, which interprets its own segment of the same chain. Restartable from any
  frame; idempotent (reconcile-to-running).
- **The Python bootstrapper is the metal-frame instance** of that exact pattern — provision the metal
  frame, build/install the pb, hand off — with two caveats the cookbook reuses: the *build* step is
  parent-orchestrated (the child pb does not exist yet), and the container frame *skips* the build
  (`docker run img project up`). Recursion bottoms out at the container pb, which runs kind/harbor/web
  as `kubectl`/`helm` leaves.
- **`.dhall` is parameters + context + witness, never the shape.** Each pb reads the sibling
  `<project>.dhall`, verifies it occupies the frame the `.dhall` describes, and fails fast on a wrong
  handoff before any side effect (see [dhall_topology](dhall_topology.md)).

## Step Kinds

Orthogonal to topology: each entry in the chain is a `Step` of one kind. The **Step algebra is the
reuse unit**. Core ships the host-management step kinds; the project contributes its own kinds into the
same `[Step]`, and host and workload steps interleave freely. This is the workload-extension seam.

| Origin | Step kinds (examples) |
|---|---|
| Core (host-management) | `deploy-vm`, `ensure-<tool>`, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`, `expose-port` |
| Project (workload) | `deploy-harbor`, `push-image`, … contributed by the consumer |

The canonical taxonomy of step semantics — converge / context-lift / one-shot action / control-loop /
run-to-completion, plus each kind's plan/apply, retry behaviour, and L0/L1/L2 layer — lives in
[composition_methodology](../architecture/composition_methodology.md); this cookbook composes steps of
those kinds across the topologies above. Which layer contributes which kind is
[library_hierarchy](../architecture/library_hierarchy.md).

## Single Representation: The Chain Is The Representation

One operation has one representation; the chain `[Step]` **is** that representation. A project's deploy
is the single ordered `[Step]` its `chain` function returns, and `project up` is the one interpreter
that walks it. The canonical home is
[composition_methodology § Single Representation](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation)
(and [development_plan_standards § W](../../DEVELOPMENT_PLAN/development_plan_standards.md)); the
summary for shape 2:

- The shape-2 chain stands up a persistent stack as one descent: `project up` interprets it across the
  composed frame stack — the metal frame provisions the VM and rebuilds the binary + project image in
  it, the in-VM frame mints the project-container child config and hands off, and the in-container frame
  runs deploy-kind → deploy-harbor → push-image → deploy-chart → expose-port. The chain ends at a live
  web service.
- The standardized harness (`HostBootstrap.Harness`: `runMatrix` + `Seams`) is a **separate** test
  surface, frame-agnostic — it runs its reconcilers (e.g. `clusterUp`) as `HostConfig -> IO ()`
  with no second bring-up path inside it. `test run all` drives the real `project up`.
- The harness, per distinct test config, writes a test `<project>.dhall`, runs `project up` (the Test
  profile, under `.test_data/`), asserts the live stack in-frame, and tears it down with `project destroy`
  — guaranteed even if a body fails. It reuses the same chain `project up` stands up, so there is no
  separate per-case bring-up. There is one representation of the deploy, and the chain is it.

## Business-Logic Composition Shapes

The same algebra composes runtime logic. Each is an extension (L1/L2 via the extension-stream merge) that
relies only on an L0 affordance (the role-lifecycle skeleton, Dhall config/schema-gen, the extension
streams) — so L0 hosts it without modification.

- **Message-bus + object-store workflow** — a stateless **role** consumes a request topic, dispatches
  to a consumer engine, publishes a result topic; static artifacts ride the object store by reference; a
  hydrator role concentrates WAN egress; batching/scheduler policy is the scaling composition point; a
  lifecycle reconciler realizes declared topic/bucket lifecycle. The workflow is a declared topology
  (request-response / fan-out-in / batched / pipeline / stream) as data.
- **Webservice / SPA** — a serving role whose API and UI are generated from typed Dhall (config-gen +
  the schema-gen registry stream); the in-tree demo webapp is the minimal instance, an arbitrary-SPA
  Dhall DSL the aspirational extension.

## Cross-Cutting Concerns

Reused across shapes and step kinds:

- **Budget cordon at every boundary** via the one canonical parser — a sized VM, the kind-node
  `docker update` cap, `docker run` caps (see [applied_cordon](applied_cordon.md) and
  [resource_budgeting](resource_budgeting.md)).
- **Teardown discipline** — teardown recurses *in* (the frame is still up) then stops/deletes on the
  ascent (the VM stopped last); best-effort and idempotent, tolerating a partial stack; never-delete-
  `.data`, name-prefix delete-guards, and resource-class lifecycle ownership (per-run / long-lived /
  operational); see [cluster_lifecycle](cluster_lifecycle.md).
- **Plan→Apply** — `project up --dry-run` renders `chain rootCfg` (the planned step sequence) before
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

## Current Status

The **chain surface** this cookbook describes is the running system: the core command tree is exactly
`ensure`, `context`, `project`, `test`, `check-code`, and the demo's deploy is the pure value
`demoChain :: ProjectConfig -> [Step]` (`demo/src/HostBootstrapDemo/Commands.hs`), which realizes shape
2 as one ordered chain that stands up the persistent stack and ends at a live web service. The lift
primitive uses provider-backed folds for Incus and Lima and a topology-aware binary-context gate. The
reconcilers (`clusterUp`, `clusterCreate`, `deployChart`, `clusterDown`, `clusterDelete`) live in
`HostBootstrap.Cluster.Lifecycle`, invoked by the chain steps and the lifecycle command.

The `chain :: ProjectConfig -> [Step]` value, the recursive `project up` interpreter, the core Step
algebra, the workload-contributed step kinds, and fractal teardown via `project down`/`project destroy`
compose end-to-end: a single `project up` on Incus/Linux stands up the live persistent stack — a
cordoned kind cluster, the production Harbor, the project image pushed to the in-cluster registry, and
the web chart pod serving `localhost:30080` — and `project down`/`project destroy` tear it down with
host `.data` preserved. The demo's status is tracked in
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
