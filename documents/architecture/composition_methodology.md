# Composition Methodology: Operations, Self-Reference Lifts, And Deploy ≡ Business-Logic

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [binary_context_config](binary_context_config.md), [library_hierarchy](library_hierarchy.md), [run_models](run_models.md)

> **Purpose**: Define the foundational composition model of `hostbootstrap-core` — a project binary
> composes **operations**, crosses execution-context boundaries by **invoking itself** (the
> self-reference lift), and expresses both deployment and runtime business logic through the **same**
> algebra.

## TL;DR

- The foundational unit is a composable **operation**, not a fixed command. A project binary sequences
  operations; the `optparse-applicative` command tree makes composition a plain Haskell value.
- The **self-reference lift** is the operation that crosses an execution-context boundary: the binary
  re-invokes its *own* subcommand in a nested context. VM hops are provider-backed (`limactl shell
  <instance> -- …` on Apple Silicon, `incus exec <vm> -- …` on native Linux); container hops are
  `docker run --rm <image> <subcmd>` with the binary as `ENTRYPOINT`. Each nested call runs the same
  command tree and reads the sibling `<project>.dhall` runtime check so the binary can validate where it
  is in the global chain. See
  [`HostBootstrap.Lift`](hostbootstrap_core_library.md).
- The same algebra expresses **deployment** (the bootstrap topology) and **runtime business logic** (the
  runtime topology): both are declarative topologies over durable external stores, executed by stateless
  **roles**. "Bring up a cluster" and "run an inference/training pipeline" are the same kind of
  composition at different altitudes.
- `hostbootstrap-core` (L0) owns the generic primitive (the algebra, the lift, the `ensure` kind, the
  role-lifecycle skeleton, run-model selection); concrete higher operation kinds and the specific chain
  of lifts are contributed per the [library hierarchy](library_hierarchy.md) (L1/L2) and are project
  logic.
- **One operation, one representation.** The standardized test harness (`HostBootstrap.Harness`) is the
  one context-agnostic test engine, so it is a **lift target**, not a lift-aware component; a consumer's
  deploy is a **single** lift sequence whose only compute step lifts the *whole* test workflow into the
  project container in the VM. A parallel chain of lifted cluster/Harbor/web-serve/e2e ops is a redundant
  second representation. See [§ Single Representation](#single-representation-the-test-workflow-is-a-lifted-operation).

## The Composable Operation

An operation is a composable step a binary runs and reports. Operations **sequence, nest in a context,
branch, retry, loop, and observe**. They differ in execution semantics, and the difference drives
plan/apply, retry, and run-model selection:

| Operation kind | Semantics | Target / control plane | Layer |
|---|---|---|---|
| `ensure` reconciler | idempotent converge | the local host | L0 |
| **self-reference lift** | run a subcommand in a nested context | the same binary, elsewhere | L0 |
| cloud / IaC deploy | plan→apply converge | a remote API + external state backend | L2 |
| REST / RPC | one-shot request→response | an external/in-cluster endpoint | L1/L2 |
| pub/sub publish | at-least-once async action | a message-bus topic | L1 |
| observe-and-scale | continuous/periodic control loop | read a signal → mutate a deployment | L1 |
| finite-job lifecycle | run-to-completion / scheduled | one-off or repeating jobs | L1 |

`ensure` (the install-and-verify reconciler, see [ensure_reconcilers](../engineering/ensure_reconcilers.md))
and the self-reference lift are the two operation kinds L0 ships. The rest are an **open, extensible
set** added through the four-stream merge (see [library_hierarchy](library_hierarchy.md)); L0 carries no
message-bus or cloud dependency.

## The Self-Reference Lift

Execution contexts compose as a stack of provider-backed layers, outermost-first; the empty stack is the
local host. A binary crosses a boundary by invoking *itself* in the nested context — there is no separate
"remote-exec" abstraction threaded through every step. The reconcilers stay context-agnostic
(`HostConfig -> IO ()`); a step is lifted purely by *where* the self-invocation places it.

| Context layer | Crossing | The binary in that context |
|---|---|---|
| `Local` | run directly | the running executable (`getExecutablePath`) |
| `InVM` via Lima | `limactl shell <instance> -- …` | the binary the VM bootstrap installed on the Lima Linux VM's `$PATH` |
| `InVM` via Incus | `incus exec <vm> -- …` | the binary the VM bootstrap installed on the Incus VM's `$PATH` |
| `InContainer` | `docker run --rm <image> …` | the project container's `ENTRYPOINT` (the binary) |

The argv fold is pure (so it is unit-tested): only the outermost host dispatch names a tool the resolver
maps to an absolute path; every nested tool is the target's own bare `$PATH` name (see
[development_plan_standards § K](../../DEVELOPMENT_PLAN/development_plan_standards.md)). A
`VM`-then-`Container` nesting folds to `limactl shell <instance> -- docker run --rm <image>
<subcmd>` on Apple Silicon or `incus exec <vm> -- docker run --rm <image> <subcmd>` on native Linux.
This generalizes VM providers from the two-case `HostTarget = Local | InVM` tool-level lift to an n-level
subcommand lift.

Every normal nested invocation reads `<project>.dhall` next to the binary before
command dispatch. The command tree is still the same everywhere, but a copy of the binary can explicitly
reason about whether it is the host orchestrator, the VM binary, the project container on the VM, or a
service pod.

- **WRONG**: a project threads an explicit "execution context" parameter through every reconciler and
  cluster step so they can run "in the VM". This is wrong because it duplicates dispatch logic in every
  operation and couples each step to the context machinery — the very thing the command tree already
  composes for free.
- **RIGHT**: the project sequences ordinary steps and crosses a boundary by lifting a subcommand
  (`liftSubcommand cfg self (inContainer ctr localContext) ["test","all"]`, where `ctr` is the
  project-container `ContainerLift`); inside the container the binary reads its sibling context file,
  verifies that the test workflow belongs in that container context, and then runs as local, resolving
  `helm`/`kind` on the container `$PATH`.

The kube tools (`kubectl`/`helm`/`kind`) are baked into the base image and used only by contexts that
declare the relevant cluster lifecycle or test-harness role (see
[development_plan_standards § L](../../DEVELOPMENT_PLAN/development_plan_standards.md) for the baked-in
kube tools, [§ U](../../DEVELOPMENT_PLAN/development_plan_standards.md) for the lift, and
[§ X](../../DEVELOPMENT_PLAN/development_plan_standards.md) for binary contexts); they are not host
tools. A failed lifted step is loud, never swallowed — the
[cluster lifecycle](../engineering/cluster_lifecycle.md) `cluster up` fails closed so a lifting parent
process sees a non-zero exit.

## Context-Aware Topology

The lift stack is not enough by itself. A command can fold to the right argv and still be illegal if the
callee's local config does not assert the same execution topology the process is actually occupying. The
project-local Dhall therefore needs to describe the complete topology as pure data, not just a flat
role name:

```dhall
{ topology =
  { frames =
    [ { id = "host"
      , parent = None Text
      , provider = ProviderKind.LocalHost
      , contextKind = ContextKind.HostOrchestrator
      , capabilities = [ Capability.HostTools ]
      , witnesses = [ ... ]
      }
    , { id = "vm"
      , parent = Some "host"
      , provider = ProviderKind.LimaVM
      , contextKind = ContextKind.VMOrchestrator
      , capabilities = [ Capability.DockerSocket ]
      , witnesses = [ RuntimeWitness.ProviderProfile ProviderKind.LimaVM "hostbootstrap-demo-vm" ]
      }
    , { id = "vm-project-container"
      , parent = Some "vm"
      , provider = ProviderKind.DockerContainer
      , contextKind = ContextKind.VMProjectContainer
      , capabilities = [ Capability.ContainerRuntime, Capability.KindNetwork ]
      , witnesses = [ ... ]
      }
    ]
  , currentFrame = "vm-project-container"
  }
, context = ...
}
```

This is deliberately a list of frames plus parent references rather than a closed recursive union. It can
represent arbitrary lifted chains — host binary -> VM -> Kubernetes cluster -> a Pulumi role that creates
an EKS cluster -> workloads in that EKS cluster — without L0 knowing every provider-specific payload. A
project or higher library layer extends the provider vocabulary and witness vocabulary; the core gate
still checks common invariants: the `currentFrame` exists, its ancestors exist, requested commands are
allowed by the current frame, required capabilities are locally verifiable, and runtime witnesses match
the process environment.

The practical rule is strict: parent code may mint a child context only for a child frame in the topology,
and a child process must fail before side effects when its local witnesses do not prove it is in that
frame. A host-side `docker run <image> test all` must therefore be rejected when the config says
`currentFrame = "vm-project-container"` under a VM parent. The test workflow may still be run locally for
development, but that requires a local test-harness frame in the Dhall, not accidental reuse of the VM
container frame.

## Binary Context: Knowing Your Place

The lift explains how a command crosses a context boundary; the binary-context config explains how the
callee decides whether the command belongs there.

Every normal command reads `<project>.dhall` from next to the executable before dispatch. The context
names the binary's position in the topology, such as host orchestrator, VM binary, project container on
the VM, or cluster service. A command whose semantics do not match that current frame fails fast with exit
code 1. For example, a service pod may serve the web role but must refuse `vm up`, a daemon command must
refuse to start unless the context declares a daemon/service role, and a kind-cluster test workflow must
refuse to run when the VM/container ancestry the Dhall declares cannot be witnessed locally.

The context contract is the canonical way to make the pure global composition visible locally without
threading a `LiftContext` through every reconciler. See
[binary_context_config](binary_context_config.md).

## Deploy ≡ Business-Logic Unification

The same algebra expresses both **deployment** — the *bootstrap* topology that stands a system up — and
**runtime business logic** — the *runtime* topology a system runs once up. Both are declarative
topologies over durable external stores (a message bus carrying work-in-flight, an object store carrying
static binary artifacts, a relational store, …), executed by **roles**: stateless long-running daemons
that subscribe to a request topic, dispatch to an engine, publish a result topic, fetch/store artifacts,
and recover by replay + refetch rather than by holding authoritative local state. The role lifecycle is
the `HostDaemon` [run-model](run_models.md); its state-machine skeleton (Load → Prereq → Acquire → Ready
→ Serve → Drain → Exit) is L0 with callback injection, while the concrete bus/store/role primitives are
L1's delta.

The invariant: **stateless roles + durable external stores + topic-as-contract = repeatable composition
without mutable coordination.** "Bring up a cluster" declares in-cluster services; "run a pipeline"
declares request/result topics and artifact buckets — the same algebra, different altitude. A
webservice/SPA is the same shape: a serving role whose API and UI are generated from typed Dhall (see
[dhall_generation](dhall_generation.md)); an arbitrary-SPA DSL is an aspirational extension built on the
streams, not baked into L0.

## Single Representation: The Test Workflow Is A Lifted Operation

An operation has exactly **one** representation. The test workflow is a **lifted** operation, not a
parallel representation of the deploy.

The standardized test harness (`HostBootstrap.Harness`: `runMatrix` + `Seams`, see
[harness_workflow](harness_workflow.md)) is the context-agnostic test engine: it brings up an isolated
per-case environment, runs the case body, and tears it down, invoking its reconcilers (e.g. `clusterUp`)
as `HostConfig -> IO ()` **locally**, unaware of any enclosing context. The harness is therefore a **lift
target**, not a lift-aware component — there is **no** `LiftContext` inside it, and that is correct (it is
exactly the context-agnostic reconciler the self-reference-lift rule requires).

A consumer composes its deploy as a **single** explicit lift sequence whose final compute step **lifts the
whole test workflow** into the project container in the VM: it folds to
`limactl shell <instance> -- docker run --rm <image> test all` on Apple Silicon or
`incus exec <vm> -- docker run --rm <image> test all` on native Linux. Inside that one lifted context the harness runs
`clusterUp` "locally" = on the VM's Docker (the mounted socket), so the kind cluster lives **in the VM**,
reached with **no** second "bring up a cluster" path.

- **WRONG**: re-expressing cluster bring-up / Harbor / web-serve / e2e as a **separate** chain of lifted
  ops *alongside* the harness. This is wrong because it is a redundant second representation of the same
  operation: it duplicates the harness, and it even double-creates clusters when that separate chain lifts
  a harness case (the case stands up its own per-case cluster too). There is one representation, and the
  harness is it.
- **RIGHT**: the deploy is a single lift sequence whose only compute step is `test all` lifted into
  `inContainer img (inVM vm localContext)`; the in-cluster bring-up, deploy, and e2e are the harness's job
  inside that one lifted context, not separate lifted steps. The child Dhall names that frame explicitly,
  and the binary verifies it before creating a kind cluster.

The single canonical demo chain — the `demo deploy` sequence — is exactly this:

| Step | Context | Role |
|---|---|---|
| `vm ensure` | `localContext` | reconcile the platform VM provider: Lima on Apple Silicon, native Incus on Linux |
| `vm up` | `localContext` | cordon #1 (the VM is the wall) |
| `vm pristine-bootstrap` | `localContext` → VM | build #2 (host-native) + build #3 (project image), in the VM |
| `test all` | `inContainer img (inVM vm localContext)` | the **only** lifted compute step; folds through the selected VM provider, then `docker run --rm <image> test all` |
| `vm down` | `localContext` | guarded teardown (`.data` preserved) |

The deploy crosses two cordons (the VM at `vm up`, the in-cluster cap inside the harness) and performs two
of the three builds inside the VM at `vm pristine-bootstrap`; the lone lifted compute step is `test all`.
This is the same self-reference lift as everywhere else — the harness is just the thing being lifted.

## Current Status

The single-representation doctrine is the supported demo shape. The current lift implementation has the
provider-backed folds for Incus and Colima, and the Apple Silicon `demo deploy --dry-run` path folds to
`limactl shell hostbootstrap-demo-vm -- docker run --rm ... test all`. Earlier real runs validated
the Incus/Linux shape with the kind cluster on the VM's Docker. The context-aware topology described
above is active hardening work in DEVELOPMENT_PLAN
[Phase 14](../../DEVELOPMENT_PLAN/phase-14-composition-methodology.md) and
[Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md): the existing flat role/capability
gate is not yet the full frame/witness contract, so direct-host fallbacks must be treated as development
smokes, not authoritative deploy validation.

## Foundational Principles

Three principles keep the foundation general — they are design rubric, not new mechanisms:

1. **Pure representation ⟂ effectful interpreter.** Every composed artifact — a deployment topology, a
   message topology, an ML compute graph, an inference plan, an SPA — is a *pure declarative value*
   (data / a DSL), separate from the role/engine that interprets it. "Topology as data" and Dhall
   config/schema-gen are instances of this principle.
2. **Durable external stores are an open, pluggable set** — object store, message bus, relational
   database, …; the role contract is "stateless role + durable external stores", store kinds open.
3. **Composition is recursive / self-similar.** A managed resource can itself be a
   `hostbootstrap`-managed *manager* — a cluster that owns and manages other clusters — i.e.
   deployment-as-business-logic at the fixpoint.

The test the L0 foundation must pass: any new consumer shape is expressible as *(pure representation) +
(role/interpreter) + (durable stores) + (operations composed across contexts)* through the four-stream
merge, without L0 changes.

## Layering

Concrete operation kinds and the specific chain of lifts are layered per the
[library hierarchy](library_hierarchy.md):

- **L0 — `hostbootstrap-core`**: the composition algebra, the generic operation interface, the
  self-reference lift, the `ensure` kind, run-model selection, and the role-lifecycle skeleton. No
  bus/cloud dependency.
- **L1 — `daemon-substrate`**: the business-logic composition primitives (roles, declared topologies,
  batching/scheduler policy, lifecycle reconciler, the WAN-egress hydrator).
- **L2 — consumers**: their pipelines composed from L1 roles, plus cloud/IaC deploy and concrete RPC
  endpoints.

The *specific chain* a binary runs — e.g. metal → VM → container → cluster — is project logic composed
from these primitives, never baked into L0.

## See also

- [hostbootstrap_core_library](hostbootstrap_core_library.md) — the `HostBootstrap.Lift` module surface
  and the command-tree extension contract.
- [library_hierarchy](library_hierarchy.md) — the L0/L1/L2 levels and the four-stream merge that adds
  operation kinds.
- [run_models](run_models.md) — the four run-models the algebra selects between.
- [incus](../engineering/incus.md) and [cluster_lifecycle](../engineering/cluster_lifecycle.md) — the
  `InVM` lift context and the fail-closed in-container cluster path.
- [harness_workflow](harness_workflow.md) — the `runMatrix` + `Seams` test engine that is the lift target
  of the single canonical `test all` step.
- [composition_patterns](../engineering/composition_patterns.md) — the cookbook of shapes that
  instantiate this model.
- [authoring_project_binaries](../engineering/authoring_project_binaries.md) — how a consumer composes a
  chain from those shapes.
