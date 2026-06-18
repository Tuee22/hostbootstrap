# Composition Methodology: The Chain Is The Project

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [binary_context_config](binary_context_config.md), [library_hierarchy](library_hierarchy.md), [run_models](run_models.md)

> **Purpose**: Define the foundational composition model of `hostbootstrap-core` — a project *is* its
> lift chain (`chain :: RootConfig -> [Step]`), `project up` is the recursive/fractal interpreter that
> descends the topology one frame at a time, and that single `[Step]` value is the one representation of
> both deployment and runtime business logic.

## TL;DR

- **The chain is the project.** A project binary's identity is the value `chain :: RootConfig -> [Step]`
  — an ordered list of host-management and workload steps. There is no separate command surface to
  re-derive: the chain is code, it is the single representation (§W), and `project up --dry-run` renders
  exactly that value.
- **`project up` is a recursive, fractal interpreter.** It runs the current frame's steps, then hands off
  `pb project up` into the next frame; each `pb` owns its own segment of the chain and is restartable from
  any frame. Descent is always the same shape: *provision the frame → build/install the `pb` in it → hand
  off `pb project up`*.
- **`.dhall` is parameters + context + witness, never the shape.** Each `pb` verifies it is in the frame
  its sibling `<project>.dhall` describes, or fails fast. Structural variation (skip the VM → straight to
  Docker) is a root-`.dhall` flag, so the chain stays a pure function of root parameters.
- **The Step algebra is the reuse unit.** The core ships host-management step kinds (`deploy-vm`,
  `ensure-X`, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`,
  `expose-port`); the project contributes workload step kinds (`deploy-harbor`, `launch-web`, …) into the
  *same* `[Step]`. Host and workload steps interleave freely — this is the workload-extension seam.
- **The same algebra expresses deployment and runtime business logic.** "Bring up a cluster" and "run an
  inference/training pipeline" are the same kind of composition over durable external stores at different
  altitudes; both are steps in the one chain.
- **Fractal bootstrap.** The Python bootstrapper is the **metal-frame instance** of the descent pattern,
  and the recursion bottoms out at the container `pb` running `kind`/`harbor`/`web` as `kubectl`/`helm`
  leaves. See [§ Fractal Bootstrap](#fractal-bootstrap).

## The Step And The Chain

The foundational unit is a composable **step**: an action a binary runs and reports inside one execution
frame. The whole project is the ordered list of those steps:

```haskell
chain :: RootConfig -> [Step]
```

`RootConfig` is derived purely from the root `<project>.dhall` parameters, so the chain is a pure
function — there is no hidden, imperatively assembled command graph. Steps differ in execution semantics,
and that difference drives plan/apply, retry, and run-model selection:

| Step kind | Semantics | Target / control plane | Layer |
|---|---|---|---|
| `ensure` reconciler | idempotent converge | the local host frame | L0 |
| `deploy-vm` | provision a provider VM (Lima/Incus) | the host's VM provider | L0 |
| `copy-source` / `build-pb` / `build-image` | stage source, build the `pb`, build the project image | the current frame | L0 |
| `context-init` | mint the child frame's `<project>.dhall` | the current frame | L0 |
| `deploy-kind` / `deploy-chart` / `expose-port` | cluster and workload bring-up | an in-frame cluster | L0 |
| cloud / IaC deploy | plan→apply converge | a remote API + external state backend | L2 |
| REST / RPC, pub/sub, observe-and-scale, finite-job | request, publish, control loop, run-to-completion | endpoints / bus / jobs | L1/L2 |

`ensure` (the install-and-verify reconciler, see
[ensure_reconcilers](../engineering/ensure_reconcilers.md)) and the host-management step kinds are what L0
ships. The workload kinds are an **open, extensible set** added through the four-stream merge (see
[library_hierarchy](library_hierarchy.md)); L0 carries no message-bus or cloud dependency. A project
**contributes its own step kinds** into the same `[Step]` value — the chain, not a tree of noun verbs, is
the project's primary CLI contribution.

## The Recursive `project up` Interpreter

Execution contexts compose as a stack of provider-backed frames, outermost-first; the empty stack is the
local host. `project up` is the recursive interpreter of the chain over that stack:

1. Read the sibling `<project>.dhall`, verify the current frame, and select the steps belonging to it.
2. Run those steps in order (reconcilers stay context-agnostic — `HostConfig -> IO ()` — so a step is
   lifted purely by *which frame the interpreter is in*, never by threading a context parameter through
   every reconciler).
3. At a frame boundary, **hand off**: invoke `pb project up` inside the next frame; that child binary owns
   its own segment of the chain and runs the same interpreter recursively.

| Context frame | Hand-off crossing | The binary in that frame |
|---|---|---|
| `Local` (metal) | run directly | the running executable (`getExecutablePath`) |
| `InVM` via Lima | `limactl shell <instance> -- … project up` | the `pb` the VM descent installed on the Lima VM's `$PATH` |
| `InVM` via Incus | `incus exec <vm> -- … project up` | the `pb` the VM descent installed on the Incus VM's `$PATH` |
| `InContainer` | `docker run <image> project up` | the project container's `ENTRYPOINT` (the `pb`) |

`project up` is idempotent — it reconciles toward the running stack — and restartable from any frame, so a
partial descent resumes cleanly. `project up --dry-run` renders `chain rootCfg` without effects.
`project down` stops services/clusters/VMs (`incus`/`limactl` **stop**) and deletes nothing; `project
destroy` stops then deletes everything the chain spun up. **Teardown recurses in** while each frame is
still up, then stops/deletes on the ascent (the VM is stopped last); it is best-effort and idempotent,
tolerating a partial stack, and `.data` is always preserved (the core invariant). See
[`HostBootstrap.Lift`](hostbootstrap_core_library.md).

- **WRONG**: a project threads an explicit "execution context" parameter through every reconciler and
  cluster step so they can run "in the VM". This is wrong because it duplicates dispatch in every step and
  couples each step to the context machinery — the very thing the interpreter already composes for free
  from the chain.
- **RIGHT**: the project supplies a `[Step]` value; the interpreter runs each step in whatever frame it
  has descended into and crosses boundaries by handing off `pb project up`. Inside the child frame the
  binary reads its sibling `<project>.dhall`, verifies the step belongs there, and runs as local.

The kube tools (`kubectl`/`helm`/`kind`) are baked into the base image and used only by frames that
declare the relevant cluster or workload step (see
[development_plan_standards § L](../../DEVELOPMENT_PLAN/development_plan_standards.md) for the baked-in
kube tools, [§ U](../../DEVELOPMENT_PLAN/development_plan_standards.md) for the lift, and
[§ X](../../DEVELOPMENT_PLAN/development_plan_standards.md) for binary contexts). A failed step is loud,
never swallowed — a deploy step fails closed so a handing-off parent sees a non-zero exit (see
[cluster_lifecycle](../engineering/cluster_lifecycle.md)).

### Forwarding credentials across the hand-off

A frame that pulls an image from Docker Hub (a VM `docker build`, a container's `kind`/`docker run`) hits
the unauthenticated rate limit. Because every binary at every frame knows its place in the chain, the
**host** binary — the only frame that holds the host's Docker Hub login — forwards that credential down
the descent so the nested pull authenticates. The credential is an effect-only, non-serialisable
capability (`HostBootstrap.Registry`): it is **never** in a `<project>.dhall` (it has no Dhall codec),
never written to a persisted file, and never in `argv`. It travels only on ephemeral channels — piped on
`stdin` into a transient `DOCKER_CONFIG` removed on exit, or carried as an environment **name** the
in-container binary consumes once and scrubs. See
[registry_credentials](../engineering/registry_credentials.md).

## Fractal Bootstrap

Every descent is the *same* three-beat pattern: **provision the frame → build/install the `pb` in it →
hand off `pb project up`**. The interpreter is self-similar all the way down, with three caveats that the
model makes explicit rather than hides:

- The **Python bootstrapper is the metal-frame instance** of that exact pattern: it provisions the metal
  frame (host prerequisites), builds/installs the `pb`, and hands off to `pb project up`. It is not a
  special case — it is the first turn of the recursion. See
  [python_haskell_boundary](python_haskell_boundary.md).
- The **build step is parent-orchestrated**: at a frame boundary the child `pb` does not exist yet, so the
  parent frame builds/installs it before it can hand off.
- The **container frame skips the build** (`docker run <image> project up`), because the project image
  already carries the `pb` as its `ENTRYPOINT`. Recursion **bottoms out** at the container `pb`, which
  runs `kind`/`harbor`/`web` steps as `kubectl`/`helm` leaves — no further frame to descend into.

## Context-Aware Topology

A hand-off can fold to the right `argv` and still be illegal if the callee's local config does not assert
the same frame the process actually occupies. The local Dhall describes that topology as pure **data**,
not just a role name — the chain shape is code, the `.dhall` is parameters + context + witness:

```dhall
{ context =
  { topologyFrames =
    [ { topologyFrameId = "host-orchestrator-0"
      , topologyParentId = ""
      , topologyProvider = ProviderKind.HostProvider
      , topologyKind = ContextKind.HostOrchestrator
      , topologyRoleName = "host-orchestrator"
      }
    , { topologyFrameId = "vm-orchestrator-1"
      , topologyParentId = "host-orchestrator-0"
      , topologyProvider = ProviderKind.LimaVMProvider
      , topologyKind = ContextKind.VMOrchestrator
      , topologyRoleName = "vm-orchestrator"
      }
    , { topologyFrameId = "vm-project-container-2"
      , topologyParentId = "vm-orchestrator-1"
      , topologyProvider = ProviderKind.DockerContainerProvider
      , topologyKind = ContextKind.VMProjectContainer
      , topologyRoleName = "vm-project-container"
      }
    ]
  , currentFrame = "vm-project-container-2"
  , runtimeWitnesses =
    [ { witnessKind = WitnessKind.WitnessUnixSocket
      , witnessName = "/var/run/docker.sock"
      , witnessValue = ""
      }
    , { witnessKind = WitnessKind.WitnessEnvEquals
      , witnessName = "HOSTBOOTSTRAP_CURRENT_FRAME"
      , witnessValue = "vm-project-container-2"
      }
    ]
  , ...
  }
}
```

This is a list of frames plus parent references rather than a closed recursive union, so it represents
arbitrary descents — host `pb` → VM → Kubernetes cluster → a Pulumi step that creates an EKS cluster →
workloads in that EKS cluster — without L0 knowing every provider-specific payload. The core gate checks
common invariants: the `currentFrame` exists, its ancestors exist, the requested step is allowed by the
current frame, required capabilities are declared, and runtime witnesses match the process environment. A
host-side `docker run <image> project up` is rejected when the config says `currentFrame =
"vm-project-container-2"` under a VM parent. See [binary_context_config](binary_context_config.md).

## Deploy ≡ Business-Logic Unification

The same `[Step]` algebra expresses both **deployment** — the *bootstrap* topology that stands a system up
— and **runtime business logic** — the *runtime* topology a system runs once up. Both are declarative
topologies over durable external stores (a message bus carrying work-in-flight, an object store carrying
static artifacts, a relational store, …), executed by **roles**: stateless long-running daemons that
subscribe to a request topic, dispatch to an engine, publish a result topic, fetch/store artifacts, and
recover by replay + refetch rather than by holding authoritative local state. The role lifecycle is the
`HostDaemon` [run-model](run_models.md); its state-machine skeleton (Load → Prereq → Acquire → Ready →
Serve → Drain → Exit) is L0 with callback injection, while the concrete bus/store/role primitives are L1's
delta.

The invariant: **stateless roles + durable external stores + topic-as-contract = repeatable composition
without mutable coordination.** "Bring up a cluster" declares in-cluster services; "run a pipeline"
declares request/result topics and artifact buckets — the same algebra, different altitude, both as steps
in the one chain. A webservice/SPA is the same shape: a serving role whose API and UI are generated from
typed Dhall (see [dhall_generation](dhall_generation.md)).

## Single Representation: The Chain Is The Representation

A project has exactly **one** representation: the `[Step]` chain (§W). Deployment, teardown, and the
visualization of the topology are all reads or interpretations of that single value — there is never a
parallel hand-assembled second chain that could drift from it.

- `project up` interprets the chain to bring up a **persistent stack**; `project down`/`project destroy`
  interpret it for teardown; `--dry-run` renders it; `context` introspects it (see
  [§ Current Status](#current-status)).
- `test run all` validates the live stack **from the root**, decoupled from deploy: the test surface
  reads its own `test.dhall` and is a chain step like any other, lifted into the frame that owns it.
- The standardized test harness (`HostBootstrap.Harness`: `runMatrix` + `Seams`, see
  [harness_workflow](harness_workflow.md)) is the context-agnostic test **engine** — a step's lift target,
  not a lift-aware component. It brings up an isolated per-case environment, runs the case, and tears it
  down, invoking reconcilers (e.g. `clusterUp`) as `HostConfig -> IO ()` locally; the interpreter, not the
  harness, decides which frame it runs in.

- **WRONG**: re-expressing cluster bring-up / Harbor / web-serve / e2e as a **separate**, hand-written
  chain of lifted ops *alongside* the steps already in `[Step]`. This is wrong because it is a redundant
  second representation of the same project: it duplicates the chain and can drift from it. There is one
  representation — the `[Step]` value the core interprets.
- **RIGHT**: every host and workload action is a step contributed into the one `[Step]`; `project up`
  interprets it, descending frame by frame, and the child Dhall names each frame explicitly so the binary
  verifies it before acting.

## Current Status

The lift primitive is built: the core has provider-backed folds for Incus and Lima, the binary-context
gate is topology-aware (runtime configs carry provider-backed frames, a current frame, and locally
checked witnesses), and the single canonical demo chain runs end-to-end. **What is implemented and
real-run-validated today is the unified lifecycle surface** — the core command tree is exactly `ensure`,
`context`, `project`, `test`, and `check-code`. The demo contributes its deploy as the pure value
`demoChain :: ProjectConfig -> [Step]` in `demo/src/HostBootstrapDemo/Commands.hs` (there is no separate
hand-written deploy sequence — the old `HostBootstrapDemo.Chain` is deleted), and retains only the `web`
verb plus the `vm`/`incus` debug-hatch verbs. The single lifted compute step is `test all` lifted into the
project container in the VM.

`project init|up|down|destroy` is the recursive lifecycle interpreter driven by the
`chain :: RootConfig -> [Step]` value: `project up` descends the 3-frame fractal topology
(`host-orchestrator-0` → `vm-orchestrator-1` → `vm-project-container-2`), `project down` stops services,
clusters, and VMs (incus/Lima **stop**) without deleting, and `project destroy` deletes them — both
preserving durable host `.data` (§ O). `context` is read-only introspection (`inspect`/`path`/`show`/
`schema`/`render`), and `test init` writes `<project>.test.dhall` while `test run <suite>|all` runs the
standardized harness. The old flat verbs have dissolved into chain steps: `cluster up` → the
`deploy-kind`/`deploy-chart` steps, `cluster down`/`delete` → `project down`/`destroy`, `cluster status` →
`context inspect`; `config init` → `project init` and `config show|schema|render` → `context show|schema|
render`; `context create` → the `context-init` step that mints the child `<project>.dhall`; the demo's
`harbor install`/`harbor push` → the `deploy-harbor`/`push-image` container-frame steps. A single
`project up` on Incus/Linux stood up the live persistent stack end-to-end — a cordoned kind cluster (kind
`extraPortMappings` publish NodePorts to the VM localhost) → the full 8-pod production Harbor
(NodePort 30500) → the 20GB project image pushed to the in-cluster registry → the web chart pod at
`localhost:30080` serving HTTP 200 — then `project down`/`project destroy` tore it down with host `.data`
preserved. `DEVELOPMENT_PLAN/` owns the migration status and closure criteria; this document is the
canonical statement of the model the validated build ships.

## Foundational Principles

Three principles keep the foundation general — design rubric, not new mechanisms:

1. **Pure representation ⟂ effectful interpreter.** The chain (and every composed artifact — a deployment
   topology, a message topology, an ML compute graph, an SPA) is a *pure declarative value*, separate from
   the interpreter that runs it. "Topology as data" and Dhall config/schema-gen are instances of this.
2. **Durable external stores are an open, pluggable set** — object store, message bus, relational
   database, …; the role contract is "stateless role + durable external stores", store kinds open.
3. **Composition is recursive / self-similar.** Descent is fractal, and a managed resource can itself be a
   `hostbootstrap`-managed *manager* — a cluster that owns and manages other clusters — deployment-as-
   business-logic at the fixpoint.

The test the L0 foundation must pass: any new consumer shape is expressible as *(pure `[Step]` chain) +
(interpreter) + (durable stores) + (steps composed across frames)* through the four-stream merge, without
L0 changes.

## Layering

Concrete step kinds and the specific chain are layered per the
[library_hierarchy](library_hierarchy.md):

- **L0 — `hostbootstrap-core`**: the composition algebra, the Step interface, the recursive `project up`
  interpreter, the host-management step kinds, the `ensure` kind, run-model selection, and the
  role-lifecycle skeleton. No bus/cloud dependency.
- **L1 — `daemon-substrate`**: the business-logic step primitives (roles, declared topologies,
  batching/scheduler policy, lifecycle reconciler, the WAN-egress hydrator).
- **L2 — consumers**: their pipelines composed from L1 roles into the chain, plus cloud/IaC deploy and
  concrete RPC endpoints.

The *specific chain* a binary runs — e.g. metal → VM → container → cluster — is project logic composed
from these primitives, never baked into L0.

## See also

- [hostbootstrap_core_library](hostbootstrap_core_library.md) — the `HostBootstrap.Lift` module surface
  and the command-tree / step-extension contract.
- [binary_context_config](binary_context_config.md) — how a frame verifies its place before acting.
- [library_hierarchy](library_hierarchy.md) — the L0/L1/L2 levels and the four-stream merge that adds step
  kinds (stream 1 = the lift chain).
- [run_models](run_models.md) — the four run-models the interpreter selects between per step.
- [incus](../engineering/incus.md) and [cluster_lifecycle](../engineering/cluster_lifecycle.md) — the
  `InVM` frame and the fail-closed in-container cluster path.
- [harness_workflow](harness_workflow.md) — the `runMatrix` + `Seams` test engine that is the lift target
  of the `test run all` step.
- [composition_patterns](../engineering/composition_patterns.md) — the cookbook of shapes that instantiate
  this model.
- [authoring_project_binaries](../engineering/authoring_project_binaries.md) — how a consumer authors its
  `chain :: RootConfig -> [Step]`.
