# Composition Patterns: A Cookbook Of Lift Shapes And Operation Kinds

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](../architecture/composition_methodology.md)

> **Purpose**: A cookbook of reusable composition shapes — context topologies, operation kinds, and
> business-logic shapes — so a downstream author can recognize their workflow and compose it as a
> self-referential project binary.

## TL;DR

- A workflow is **operations** (what a step does) composed across a **context topology** (where a step
  runs — the self-reference lift stack). The two axes are orthogonal; this cookbook catalogues both.
- The shapes below are generic; any consumer composes its specific chain from them. The foundational
  model is [composition_methodology](../architecture/composition_methodology.md); the layering of who
  contributes which operation kind is [library_hierarchy](../architecture/library_hierarchy.md).
- A third group, **business-logic shapes**, shows the same algebra composing runtime logic (roles over
  durable external stores), not just deployment.

## Context Topologies

Each topology is a lift stack (outermost-first); a binary crosses each boundary by invoking its own
subcommand there (`incus exec` for a VM, `docker run --rm` for a container).

1. **One-shot container lift** — `host → docker run --rm <project-container> <pb> <verb>`. Run a tool the
   host lacks (a cloud CLI, `helm`) inside the project container. The atom every other shape builds on.
2. **Pristine-host VM bootstrap** — `host → VM (re-establish the binary host-native) → container → deploy`.
   The worked [demo](../operations/demo_runbook.md); the no-copy-out rebuild-in-context case. Its deploy is
   a **single** lift sequence whose only lifted compute step lifts the *whole* test workflow into the
   project container in the VM — `test all` in `inContainer img (inVM vm localContext)`, folding to
   `incus exec <vm> -- docker run --rm <image> test all` — not a parallel chain of lifted cluster/web-serve/e2e
   ops (see [single representation](#single-representation-applied-to-shape-2-pristine-host-vm-bootstrap)).
3. **Host → managed cloud cluster** — build the container, then a container-lift uses a cloud CLI to
   provision a managed Kubernetes cluster against an external state backend, then a second container-lift
   runs `helm` into it. No VM; the cloud is the substrate.
4. **Local cluster via a host service manager** — bring a cluster up as a host `systemd`/`launchd` service
   (e.g. `rke2`/`k3s`), deploy into it, optionally layer cloud-validation stacks via an in-cluster state
   store.
5. **Phased, registry-first cluster bring-up** — within a cluster context, an ordering shape: stand up
   storage + database + **registry foundation first**, mirror all images through the in-cluster registry,
   then platform services, then the workload chart.
6. **Host-native daemon bridged to an in-cluster coordinator** — the binary also runs as a long-lived
   host daemon (singleton via a file lock) an in-cluster workload reaches over a message bus, used when a
   capability (an accelerator) is reachable only on the host. The `HostDaemon`
   [run-model](../architecture/run_models.md).
7. **Build-only VM for platform-locked artifacts** — lift a *build* into an ephemeral VM to produce a
   platform-specific artifact, copy it out, never run the workload in the VM (the `ensure tart` shape).
8. **GPU cluster variant** — substrate-select a GPU cluster (device-plugin / GPU-aware kind /
   `RuntimeClass`) and pin accelerator-owning pods; the same chains with a GPU node.

## Single Representation Applied To Shape 2 (Pristine-Host VM Bootstrap)

One operation has one representation; the test workflow is a **lifted** operation, not a parallel
representation of the deploy. The canonical home for this doctrine is
[composition_methodology § Single Representation](../architecture/composition_methodology.md#single-representation-the-test-workflow-is-a-lifted-operation)
(and [development_plan_standards § W](../../DEVELOPMENT_PLAN/development_plan_standards.md)); the summary
for shape 2:

- The standardized harness (`HostBootstrap.Harness`: `runMatrix` + `Seams`) is context-agnostic — it runs
  its reconcilers (e.g. `clusterUp`) as `HostConfig -> IO ()` "locally", so it is a **lift target**, not a
  lift-aware component (no `LiftContext` inside it).
- The shape-2 deploy is therefore a single lift sequence whose only compute step lifts the *whole* harness:
  `test all` in `inContainer img (inVM vm localContext)`. Inside that one lifted context the harness runs
  `clusterUp` on the VM's Docker, so the kind cluster lives **in the VM**, reached with no second
  "bring up a cluster" path.
- Standing up cluster/Harbor/web-serve/e2e as a **separate** chain of lifted ops alongside the harness is a
  redundant second representation (it duplicates the harness and double-creates clusters when it lifts a
  harness case). There is one representation, and the harness is it.

The single canonical chain (`demo deploy`) is `ensure incus` (local) → `vm up` (local, cordon #1) →
`vm pristine-bootstrap` (local → VM: build #2 host-native + build #3 project image) → `test all` (the only
lifted compute step) → `vm down` (local, guarded teardown). Whether the worked demo realizes this yet is
tracked in [Phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md).

## Operation Kinds

Orthogonal to topology: each step is an operation of one kind. The canonical taxonomy — the kinds, their
semantics (converge / context-lift / one-shot action / control-loop / run-to-completion), their plan/apply
and retry behaviour, and their L0/L1/L2 layer — lives in
[composition_methodology](../architecture/composition_methodology.md); this cookbook composes operations
of those kinds across the topologies above. Which layer contributes which kind is
[library_hierarchy](../architecture/library_hierarchy.md).

## Business-Logic Composition Shapes

The same algebra composes runtime logic. Each is an extension (L1/L2 via the four-stream merge) that
relies only on an L0 affordance (the role-lifecycle skeleton, Dhall config/schema-gen, the extension
streams) — so L0 hosts it without modification.

- **Message-bus + object-store workflow** — a stateless **role** consumes a request topic, dispatches to a
  consumer engine, publishes a result topic; static artifacts ride the object store by reference; a
  hydrator role concentrates WAN egress; batching/scheduler policy is the scaling composition point; a
  lifecycle reconciler realizes declared topic/bucket lifecycle. The workflow is a declared topology
  (request-response / fan-out-in / batched / pipeline / stream) as data.
- **Webservice / SPA** — a serving role whose API and UI are generated from typed Dhall (config-gen +
  the schema-gen registry stream); the in-tree demo webapp is the minimal instance, an arbitrary-SPA
  Dhall DSL the aspirational extension.

## Cross-Cutting Concerns

Reused across shapes and kinds:

- **Budget cordon at every boundary** via the one canonical parser — a sized VM, the kind-node
  `docker update` cap, `docker run` caps (see [applied_cordon](applied_cordon.md) and
  [resource_budgeting](resource_budgeting.md)).
- **Teardown discipline** — never-delete-`.data`, name-prefix delete-guards, and resource-class lifecycle
  ownership (per-run / long-lived / operational); see [cluster_lifecycle](cluster_lifecycle.md).
- **Plan→Apply** — a dry-run that prints the planned operation/argv sequence before the mutating apply.
- **Substrate multiplexing** — the same pure workflow parameterized over `(model × substrate)` under one
  control-plane contract.
- **The whole test workflow lifts as one operation** — the consumer's deploy lifts the *entire* harness
  (`test all`) into the project container in the VM as its single compute step; the harness itself stays
  context-agnostic and may further lift a case into the cluster as a Job (a finite-job operation). It is
  one representation, not a parallel chain of lifted cluster/e2e ops; see
  [single representation](#single-representation-applied-to-shape-2-pristine-host-vm-bootstrap) and
  [harness_workflow](../architecture/harness_workflow.md).

## See also

- [composition_methodology](../architecture/composition_methodology.md) — the foundational model these
  shapes instantiate.
- [authoring_project_binaries](authoring_project_binaries.md) — how to compose a chain from these shapes.
- [library_hierarchy](../architecture/library_hierarchy.md) — the four-stream merge that adds operation
  kinds.
