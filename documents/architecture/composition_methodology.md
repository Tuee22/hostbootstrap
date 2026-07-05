# Composition Methodology: The Chain Is The Project

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [binary_context_config](binary_context_config.md), [library_hierarchy](library_hierarchy.md), [run_models](run_models.md)

> **Purpose**: Define the foundational composition model of `hostbootstrap-core` — a project *is* its
> lift chain (`chain :: cfg -> [Step]`), `project up` is the recursive/fractal interpreter that
> descends the topology one frame at a time, and that single `[Step]` value is the one representation of
> both deployment and runtime business logic.

## TL;DR

- **The chain is the project.** A project binary's identity is the value `chain :: cfg -> [Step]`
  — an ordered list of host-management and workload steps. The chain is code, it is the single
  representation (§ W), and `project up --dry-run` renders exactly that value.
- **`project up` is a recursive, fractal interpreter.** It runs the current frame's steps, then hands off
  `pb project up` into the next frame; each `pb` owns its own segment of the chain and is restartable from
  any frame. Descent is always the same shape: *provision the frame → build/install the `pb` in it → hand
  off `pb project up`*.
- **`.dhall` is parameters + context + witness, never the shape.** Each `pb` verifies it is in the frame
  its sibling `<project>.dhall` describes, or fails fast. The chain is a pure function of root parameters,
  so the shape lives in code and the `.dhall` carries only parameters, context, and witnesses.
- **The Step algebra is the reuse unit.** The core ships host-management step kinds (`deploy-vm`,
  `ensure-X`, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`,
  `expose-port`); the project contributes workload step kinds (`deploy-registry`, `push-image`, …) into the
  *same* `[Step]`. Host and workload steps interleave freely — this is the workload-extension seam.
- **The same algebra expresses deployment and runtime business logic.** "Bring up a cluster" and "run an
  inference/training pipeline" are the same kind of composition over durable external stores at different
  altitudes; both are steps in the one chain.
- **Fractal bootstrap.** The Python bootstrapper is the **metal-frame instance** of the descent pattern,
  and the recursion bottoms out at the container `pb` running the `deploy-kind`/`deploy-registry`/`push-image`/`deploy-chart`/`expose-port` steps as `kubectl`/`helm` leaves. See
  [§ Fractal Bootstrap](#fractal-bootstrap).

## The Step And The Chain

The foundational unit is a composable **step**: an action a binary runs and reports inside one execution
frame. The whole project is the ordered list of those steps:

```haskell
chain :: cfg -> [Step]
```

`ProjectConfig` is derived purely from the root `<project>.dhall` parameters, so the chain is a pure
function — there is no hidden, imperatively assembled command graph. Steps differ in execution semantics,
and that difference drives plan/apply, retry, and run-model selection:

| Step kind | Semantics | Target / control plane | Layer |
|---|---|---|---|
| `ensure` reconciler | idempotent converge | the local host frame | L0 |
| `deploy-vm` | provision a provider VM (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows) | the host's VM provider | L0 |
| `copy-source` / `build-pb` / `build-image` | stage source, build the `pb`, build the project image | the current frame | L0 |
| `context-init` | mint the child frame's `<project>.dhall` and stream it in-place into that frame | the current frame | L0 |
| `deploy-kind` / `deploy-chart` / `expose-port` | cluster and workload bring-up | an in-frame cluster | L0 |
| cloud / IaC deploy | plan→apply converge | a remote API + external state backend | L2 |
| REST / RPC, pub/sub, observe-and-scale, finite-job | request, publish, control loop, run-to-completion | endpoints / bus / jobs | L1/L2 |

`ensure` (the install-and-verify reconciler, see
[ensure_reconcilers](../engineering/ensure_reconcilers.md)) and the host-management step kinds are what L0
ships. The workload kinds are an **open, extensible set** added through the extension-stream merge (see
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
| `InVM` via WSL2 | `wsl -d <distro> -- … project up` | the `pb` the VM descent installed on the WSL2 Ubuntu-24.04 distro's `$PATH` |
| `InContainer` | `docker run <image> project up` | the project container's `ENTRYPOINT` (the `pb`) |

`project up` is idempotent — it reconciles toward the running stack — and restartable from any frame, so a
partial descent resumes cleanly. `project up --dry-run` renders `chain cfg` without effects.
`project down` stops service/VM frames and deletes kind clusters while preserving durable state; provider
VMs use `incus`/`limactl` **stop**, while kind clusters use `kind delete cluster`. `project destroy` stops
then deletes everything the chain spun up. **Teardown recurses in** while each frame is still up, then
stops/deletes on the ascent (the VM is stopped last); it is best-effort and idempotent, tolerating a
partial stack, and `.data` is always preserved (the core invariant). See
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
  runs the `deploy-kind`/`deploy-registry`/`push-image`/`deploy-chart`/`expose-port` steps as `kubectl`/`helm`
  leaves — no further frame to descend into.

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

The Windows substrate folds the *same* shape with the WSL2 VM provider: on `windows-cpu`/`windows-gpu`
the `vm-orchestrator-1` frame carries `topologyProvider = ProviderKind.Wsl2VMProvider` (the peer of
`LimaVMProvider`/`IncusVMProvider`) and the host `pb` hands off with `wsl -d <distro> -- … project up`
into the Ubuntu-24.04 distro, where the `vm-project-container-2` frame is reached exactly as on the
Lima/Incus chains — only the provider builders differ. See [wsl2](../engineering/wsl2.md).

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

A project has exactly **one** representation: the `[Step]` chain (§ W). Deployment, teardown, and the
visualization of the topology are all reads or interpretations of that single value — there is never a
parallel hand-assembled second chain that could drift from it.

- `project up` interprets the chain to bring up a **persistent stack**; `project down`/`project destroy`
  interpret it for teardown; `--dry-run` renders it; `context` introspects it (see
  [§ Current Status](#current-status)).
- `test run` is a **driver** of that one representation, not a second one. It reads its own `test.dhall`
  (the case matrix plus config overrides) and, per distinct test configuration, writes a test-specific
  `<project>.dhall`, runs the **real `project up`** over the project's own chain, runs the case assertions
  in the appropriate frame, and tears down with `project destroy`. The bring-up a test exercises is the
  same chain production uses, so no resource model can drift between test and deploy.
- The standardized test harness (`HostBootstrap.Harness`: `runMatrix` + `Seams`, see
  [harness_workflow](harness_workflow.md)) owns only the case matrix, the per-case **assertions**, and the
  test-config parameters — never a second cluster-bring-up path.
- A single `<project>.dhall` carries an explicit context and may declare **more than one role** (project
  *and* service); a context's relationship to the others is expressed in these pure compositional lifts
  (the frame graph), not implicitly.

- **WRONG**: re-expressing deploy bring-up as a **separate**, hand-written path *alongside* the chain —
  including inside a test seam that stands a cluster up a second way. This is wrong because it is a
  redundant second representation that duplicates the chain and can drift from it (it is exactly how the
  test and deploy resource models drifted before this rule).
- **RIGHT**: every host and workload action is a step contributed into the one `[Step]`; `project up`
  interprets it, descending frame by frame; and the **test harness drives that same `project up`** under a
  test config rather than re-expressing it.

## Current Status

The lift primitive is built: the core has provider-backed folds for Incus and Lima, the binary-context
gate is topology-aware (runtime configs carry provider-backed frames, a current frame, and locally
checked witnesses), and the canonical demo chain runs end-to-end. The core command tree is exactly
`project`, `test`, `service`, `context`, and `check-code` — a fixed surface with no per-project verbs. The
demo contributes its deploy as the pure value `demoChain :: ProjectConfig -> [Step]` in
`demo/src/HostBootstrapDemo/Commands.hs`, its `Web` service variant (run by `service run`), and its
VM/provider IO as chain steps.

`project init|up|down|destroy` is the recursive lifecycle interpreter driven by the
`chain :: cfg -> [Step]` value: `project up` descends the 3-frame fractal topology
(`host-orchestrator-0`, `vm-orchestrator-1`, `vm-project-container-2`), `project down` stops service/VM
frames and deletes kind clusters while preserving durable state, and `project destroy` deletes the
provisioned compute frames — both preserving durable host `.data` (§ O).

`context` is read-only introspection (`inspect`/`path`/`show`/
`schema`/`render`), and `test init` writes `<project>.test.dhall` while `test run <suite>|all` runs the
standardized harness.

`context-init` mints the child `<project>.dhall` and streams it in-place into the next frame over the lift's
`stdin` channel (no config bind-mount); `deploy-kind`/`deploy-chart`
bring up the cluster and workload; `deploy-registry`/`push-image` install the in-cluster registry and push
the project image; `context inspect` renders the topology with the current frame marked.

A single `project up` stands up the live persistent stack end-to-end — a cordoned kind cluster (a slice within the
budget-sized VM wall; kind `extraPortMappings` publish NodePorts to the VM localhost), the in-cluster
registry (NodePort 30500), the project image pushed to the in-cluster registry, and the web chart
pod at `localhost:30080` serving HTTP 200 via `service run web` — then `project down`/`project destroy` tear
it down with host `.data` preserved.

This is validated end-to-end on two of the three metal substrates:
Incus/Linux and a 16 GiB Apple-Silicon Lima host (2026-06-20).

The **third** metal substrate, Windows (WSL2 on
`windows-cpu`/`windows-gpu`, the structural peer of Lima/Incus), is implemented through platform readiness
and the managed Ubuntu-24.04 distro / in-distro Docker image build, and full end-to-end lifecycle closure
landed in phase-11 on 2026-07-01 (`test run all` `6/6` → `project destroy` on Windows; see
[wsl2](../engineering/wsl2.md)).

The decoupled `test run all` drives that **same** `project up`
under the test surface and reports `6/6 passed` (three cases × two message variants) on **both**
Apple-Silicon/Lima and native Incus/Linux. Every case — the two reachability checks and the Playwright e2e — runs in the
**VM frame**: each is a pure probe folded into the VM by the self-reference lift
(`HostBootstrap.Lift.reachLeaf`/`liftLeaf`, the generalized `foldLeaf`), so it reaches the in-cluster
NodePort whether or not the provider forwards the guest port to the host. This is the same single
representation as `project up` (one fold places any leaf — a self-subcommand handoff or a reachability
probe — into the correct frame).

This document is the canonical statement of the model the validated build
ships.

The harness's config handling is reconciled with the § W single-representation rule above. `test run all`
reads the thin `test.dhall`, generates each run's `<project>.dhall` via `psTestConfig` (reusing `psInit`),
drives `project up` against that generated config, and deletes the generated config on teardown. The
pre-existing-config flow is removed and recorded in
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). See
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md) and
[generic_project_model.md](generic_project_model.md).

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
(interpreter) + (durable stores) + (steps composed across frames)* through the extension-stream merge, without
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
- [library_hierarchy](library_hierarchy.md) — the L0/L1/L2 levels and the extension-stream merge that adds step
  kinds (stream 1 = the lift chain).
- [run_models](run_models.md) — the four run-models the interpreter selects between per step.
- [incus](../engineering/incus.md) and [cluster_lifecycle](../engineering/cluster_lifecycle.md) — the
  `InVM` frame and the fail-closed in-container cluster path.
- [harness_workflow](harness_workflow.md) — the `runMatrix` + `Seams` test engine that `test run all`
  drives, separate from the deploy chain.
- [composition_patterns](../engineering/composition_patterns.md) — the cookbook of shapes that instantiate
  this model.
- [authoring_project_binaries](../engineering/authoring_project_binaries.md) — how a consumer authors its
  `chain :: cfg -> [Step]`.
