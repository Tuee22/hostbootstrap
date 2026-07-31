# Composition Methodology: The Chain Is The Project

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [binary_context_config](binary_context_config.md), [library_hierarchy](library_hierarchy.md), [run_models](run_models.md)

> **Purpose**: Define the foundational composition model of `hostbootstrap-core`: project fragments
> produce one opaque validated `StepPlan` consumed by recursive `project up`, while the later
> `ProjectPlan scope specDigest planId configId cfg` derives receipt-bound reverse traversal,
> resource/effect authority, and verb-indexed
> receipt-driven reverse traversal from
> one validated representation. The same step algebra composes deployment and runtime business logic.

## TL;DR

- **The validated step plan is the declared forward order.** A project binary contributes additive
  `cfg -> [Step]` fragments; final projection runs `mkStepPlan`, and `project up --dry-run` renders that
  opaque plan. Validation preserves the exact order or rejects empty/duplicate/conflicting plans,
  including a non-contiguous `A1, B1, A2` return and misplaced post-handoff work, before effects. The
  Each frame that has a successor declares exactly one descent on its own plan node, so topology is
  part of the same value; the teardown single-assignment slot remains separate. The later receipt-aware
  `ProjectPlan scope specDigest planId configId cfg` rejects those shapes and derives every view from one
  representation (§ W).
- **`project up` is a recursive, fractal interpreter.** It runs the current frame's steps, then hands off
  `pb project up` into the next frame; each `pb` owns its own segment and the command can be invoked at
  any declared frame. Convergence after a partial failure is currently best-effort, not guaranteed
  restartability; Sprints 9.10 and 16.6 own durable identity-bound recovery. Descent is always the same
  shape: *provision the frame → build/install the `pb` in it → hand off `pb project up`*.
- **`.dhall` is parameters + context + witness, never the shape.** Each `pb` checks the frame its sibling
  `<project>.dhall` describes, and known mismatches fail fast. Those fields are not yet unforgeable
  authority. The chain is a pure function of root parameters, so the shape lives in code and the
  `.dhall` carries only parameters, context, and witnesses.
- **The Step algebra is the reuse unit.** The core ships host-management step kinds (`deploy-vm`,
  `ensure-X`, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`,
  `expose-port`, `post-handoff`); the project contributes workload step kinds (`deploy-minio`,
  `deploy-registry`, `push-image`, accelerator-daemon placement, …) into the *same* `[Step]`. Host and workload steps interleave freely — this is the
  workload-extension seam.
- **The same algebra expresses deployment and runtime business logic.** "Bring up a cluster" and "run an
  inference/training pipeline" are the same kind of composition over durable external stores at different
  altitudes; both are steps in the one chain.
- **Fractal bootstrap.** The Python bootstrapper is the **metal-frame instance** of the descent pattern,
  and the descent reaches the container `pb` running the `deploy-kind`/`deploy-minio`/
  `deploy-registry`/`push-image`/`deploy-chart`/`expose-port` and daemon-placement steps. See
  [§ Fractal Bootstrap](#fractal-bootstrap).

## The Step And The Chain

The foundational unit is a composable **step**: an action a binary runs and reports inside one execution
frame. Project fragments declare lists, but the interpreter receives only their opaque validated result:

```haskell
addSteps :: (cfg (Production projectId) -> [Step]) -> ProjectSpecBuilder projectId cfg tcfg -> ProjectSpecBuilder projectId cfg tcfg
mkStepPlan :: [Step] -> Either StepPlanError StepPlan
```

The project-defined `cfg` is decoded from the root `<project>.dhall` parameters, so plan projection is
pure — there is no hidden, imperatively assembled command graph. Steps differ in execution semantics,
and that difference drives plan/apply and retry:

| Step kind | Semantics | Target / control plane | Layer |
|---|---|---|---|
| `ensure` reconciler | probe-first converge; typed idempotent result is target work | the local host frame | L0 |
| `deploy-vm` | provision a provider VM (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows) | the host's VM provider | L0 |
| `copy-source` / `build-pb` / `build-image` | stage source, build the `pb`, build the project image | the current frame | L0 |
| `context-init` | current: announcing frame anchor; target: one plan node projects, authenticates, and delivers the child config | the current frame | L0 |
| `deploy-kind` / `deploy-chart` / `expose-port` | cluster and workload bring-up | an in-frame cluster | L0 |
| `post-handoff` | after-child-frame lifecycle hook, e.g. host daemon startup after ingress exists | the declaring parent frame | L0 |
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
2. Run those steps in order. Current reconcilers are context-agnostic `HostConfig -> IO ()` callbacks;
   that is an implementation state, not the target result type. The target still avoids threading a raw
   `BinaryContext` through every reconciler, but each step receives its opaque scoped transition
   descriptor. The plan internally traverses the descriptor's complete edge set against the exact
   rehydrated resources, runs every required readiness probe, and seals the resulting closed snapshot
   into `OperationPreconditionSet`; prepare reruns the probes and the effect adapter receives only the
   matching fresh `PreparedOperation`/`PreparedPreconditions` pair. A caller-retained readiness
   capability never enters preparation or the adapter. The transition returns structured
   `ReconcileResult`. Placement
   is determined by the validated plan/frame, not by a caller-supplied descriptive context.
3. At a frame boundary, **hand off**: invoke `pb project up` inside the next frame; that child binary owns
   its own segment of the chain and runs the same interpreter recursively.

| Context frame | Hand-off crossing | The binary in that frame |
|---|---|---|
| `Local` (metal) | run directly | the running executable (`getExecutablePath`) |
| `InVM` via Lima | `limactl shell <instance> -- … project up` | the `pb` the VM descent installed on the Lima VM's `$PATH` |
| `InVM` via Incus | `incus exec <vm> -- … project up` | the `pb` the VM descent installed on the Incus VM's `$PATH` |
| `InVM` via WSL2 | `wsl -d <distro> -- … project up` | the `pb` the VM descent installed on the WSL2 Ubuntu-24.04 distro's `$PATH` |
| `InContainer` | normally `docker run <image> project up`; with config delivery, `docker run -i --entrypoint sh ...` writes stdin then `exec`s the `pb` | the installed project binary; the Dockerfile entrypoint is bypassed during in-place config delivery |

`project up` attempts reconcile-to-running, but most reconcilers return `IO ()` rather than an explicit
create/repair/no-op/conflict result, so typed idempotence is not yet enforced. `project up --dry-run`
resolves and renders the same `StepPlan` without effects.
`project down` stops service/VM frames and deletes kind clusters while preserving durable state; provider
VMs use provider stop, while kind clusters use `kind delete cluster`. `project destroy` invokes
the verb's reverse projection of the one plan. It does **not** recursively dispatch the verb into
every child frame before stopping/deleting the parent. Cleanup is best-effort and aggregates failures,
and neither verb places the plan's data path in its cluster-teardown removal set — `down`'s
removal set is empty and `destroy`'s holds only derived paths. The demo creates host
`<project-root>/.data` and carries it through provider shares and the stable Linux alias, so provider
deletion does not intentionally delete that host directory. End-to-end destroy/up/readback remains
unvalidated; see [durable_state](durable_state.md). A failed `project up` attempts best-effort root cleanup. An external
hard kill runs no teardown, and the next run is not proven to converge every partially owned resource.
See
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
never retained in durable project/image state, and never in `argv`. It travels through bounded transient
effects — process memory, `stdin`, an environment value, and a temporary `DOCKER_CONFIG` removed on exit.
Opacity/redaction prevents ordinary config serialization but cannot make arbitrary OS-level disclosure
unrepresentable. See
[registry_credentials](../engineering/registry_credentials.md).

Networked operations likewise cannot be assembled from unrelated strings. A finalized operation plan
jointly binds client scope, verified exposure, backend scope, and delivery strategy; redirect delivery
requires a reachability proof, and runtime admission requires the exact route observation. The
canonical algebra is [network reachability](network_reachability.md).

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
- The **container frame skips the build**, because the image already carries the installed `pb`. During
  current runtime config delivery the lift overrides the Dockerfile entrypoint with `sh`, writes the child
  config from stdin, and `exec`s the binary. That shell can deliver descriptive config but cannot perform
  the target authority handshake. Phase 15.9 replaces it with the binary's internal framed receiver on a
  private duplex broker session; the receiver verifies a challenge-bound one-time grant and config hash
  before writing config or minting scoped authority. The container binary then runs
  `deploy-kind`/`deploy-minio`/`deploy-registry`/`push-image`/`deploy-chart`/`expose-port` and selected
  daemon-placement steps.

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
recover by replay + refetch rather than by holding authoritative local state. The role lifecycle has the
`HostDaemon` execution shape in the [run-model taxonomy](run_models.md). Its historical L0 callback
skeleton named Load → Prereq → Acquire → Ready → Serve → Drain → Exit. In the target, activation,
config/secret verification, and one-use lifecycle admission replace the untyped Load callback and yield
the sole initial Prereq cursor; the core-owned runner privately drives Prereq → Acquire → Ready → Serve →
Drain → Exit. The concrete bus/store/role primitives are L1's delta.

The invariant: **stateless roles + durable external stores + topic-as-contract = repeatable composition
without mutable coordination.** "Bring up a cluster" declares in-cluster services; "run a pipeline"
declares request/result topics and artifact buckets — the same algebra, different altitude, both as steps
in the one chain. A webservice/SPA is the same shape: a serving role whose API and UI are generated from
typed Dhall (see [dhall_generation](dhall_generation.md)).

The implemented accelerator demo is the smallest hardware-backed instance of that runtime shape: the web
service accepts CBOR WebSocket connections from a project-binary daemon, dispatches an asynchronous
`Float` add request, and receives the result from a generated substrate-specific worker. Apple Silicon and
Windows GPU place that daemon on the host; Linux CPU/GPU place it in the cluster. The representation is
still the chain and context graph, not a second hidden accelerator path; see
[accelerator_daemon](../engineering/accelerator_daemon.md).

## Single Representation: The Chain Is The Representation

A project must have exactly **one lifecycle representation** (§ W). Forward order is now one opaque
`StepPlan`: typed core/project identities are disjoint, operation keys and dependency prefixes derive
from that plan, frame segments are exact and contiguous, and render/apply/frame traversal consume the
same value, and each frame's descent is a node of that same plan. The implementation has not fully
reached the receipt-aware lifecycle target: teardown remains a checked single-assignment function beside
the plan, and current teardown is a current-frame hook rather than a reverse interpretation.

The target replaces those independent inputs with one **opaque** validated plan from which forward steps,
frame topology, and reverse transitions are derived:

```haskell
data ProjectPlan scope specDigest planId configId (cfg :: Type -> Type) -- constructor hidden
data ValidatedConfig scope specDigest configId config                    -- constructor hidden
data PlanDraft scope specDigest config
data PlannedStep scope planId configId config
data DerivedTopology scope planId
data AcquisitionJournal scope planId
data LifecycleGraph scope planId
data StablePlanSnapshot
data VerifiedPlanSnapshot scope specDigest planDigest
data BoundPlanSnapshot scope specDigest planDigest planId
data PlanDigestBinding scope specDigest planDigest planId
data UnboundRunLease scope brokerGeneration
data BoundRunLease scope specDigest planDigest brokerGeneration
data NormalActiveRecovery scope specDigest planDigest planId brokerGeneration
data BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration
data BoundRevisionRecovery scope specDigest planDigest planId brokerGeneration
data OldPermitFenceSet
  scope planDigest oldBrokerGeneration brokerGeneration requiredSessionSet requiredOperationSet
data VerifiedSessionOperationManifest
  scope planDigest oldBrokerGeneration requiredSessionSet requiredOperationSet
data RehydratedResourceSet
  scope planDigest planId brokerGeneration requiredResourceSet
data RecoveredProjectFrame scope planId frame
data RecoveredTeardownStepResource
  scope planDigest planId brokerGeneration frame id resource phase operation operationKey
  -- closed private sum of owned managed evidence or a released tombstone
data ActivePlanRevision scope brokerGeneration planDigest activeRevisionVersion
data RevisionPermitAuthority
  scope planDigest planId brokerGeneration activeRevisionVersion journalVersion
data CurrentBrokerSessionAdmission scope planDigest planId brokerGeneration

data ProjectDown
data ProjectDestroy
data TeardownVerb verb where
  DownVerb    :: TeardownVerb ProjectDown
  DestroyVerb :: TeardownVerb ProjectDestroy
data TeardownPlan scope planId verb
data TeardownForest scope planId verb
data CompletedTeardownForest scope planId verb
data TeardownDescentStep
  scope planId verb frame childSet id operation operationKey next
data TeardownAuthorizationPoint scope planId verb frame childSet next
  -- closed private sum produced only by the teardown forest
data OpenProject
data ClosingProject
data ProjectOperationState scope planId version state -- constructor hidden
data DestroySettled scope planId journalVersion -- constructor hidden
data VerifiedNoProjectResourcesAcquired scope planId journalVersion -- constructor hidden
data ProjectClosureEvidence scope planId journalVersion -- constructor hidden
data ProductionClosureAuthorization
  projectId planDigest planId brokerGeneration journalVersion -- constructor hidden
data HarnessRootAuthority projectId runId brokerGeneration -- constructor hidden
data AbandonedHarnessRecoveryAuthority
  projectId runId specDigest planDigest brokerGeneration -- constructor hidden
data ProjectModeLease projectId mode brokerGeneration -- constructor hidden
data HarnessMode runId
data HarnessCloseRoot projectId runId brokerGeneration -- constructor hidden
data HarnessCloseAuthority
  projectId runId planId brokerGeneration closeEpoch -- constructor hidden
data HarnessClosePlan
  projectId runId planId brokerGeneration closeEpoch -- constructor hidden
data HarnessCloseJournal
  projectId runId planId brokerGeneration closeEpoch closeJournalVersion -- constructor hidden

-- Full version-indexed signatures are canonical in lifecycle_state_model.md.
verifyDestroySettled :: ... -> IO (Either TeardownError (DestroySettled ...))
verifyNoProjectResourcesAcquired
  :: ... -> IO (Either TeardownError (VerifiedNoProjectResourcesAcquired ...))
closureAfterDestroy :: DestroySettled ... -> ProjectClosureEvidence ...
closureBeforeFirstEffect
  :: VerifiedNoProjectResourcesAcquired ... -> ProjectClosureEvidence ...

currentHarnessCloseRoot
  :: HarnessRootAuthority projectId runId brokerGeneration
  -> HarnessCloseRoot projectId runId brokerGeneration

abandonedHarnessCloseRoot
  :: AbandonedHarnessRecoveryAuthority
       projectId runId specDigest planDigest brokerGeneration
  -> HarnessCloseRoot projectId runId brokerGeneration

withProjectPlan
  :: LifecycleProfile scope
  -> ValidatedConfig scope specDigest configId (cfg scope)
  -> NonEmpty (PlanDraft scope specDigest (cfg scope))
  -> (forall planId. ProjectPlan scope specDigest planId configId cfg -> a)
  -> Either PlanError a

withRecoveredProductionProjectPlan
  :: RecoveredProductionLifecycleProfile
       projectId specDigest planDigest planId brokerGeneration
  -> VerifiedPlanSnapshot (Production projectId) specDigest planDigest
  -> BoundPlanSnapshot (Production projectId) specDigest planDigest planId
  -> PlanDigestBinding (Production projectId) specDigest planDigest planId
  -> ValidatedConfig
       (Production projectId) specDigest configId (cfg (Production projectId))
  -> NonEmpty
       (PlanDraft
          (Production projectId) specDigest (cfg (Production projectId)))
  -> (ProjectPlan
        (Production projectId) specDigest planId configId cfg
      -> a)
  -> Either PlanError a

forward
  :: ProjectPlan scope specDigest planId configId cfg
  -> NonEmpty (PlannedStep scope planId configId (cfg scope))
topology
  :: ProjectPlan scope specDigest planId configId cfg
  -> DerivedTopology scope planId

renderSnapshot
  :: ProjectPlan scope specDigest planId configId cfg
  -> StablePlanSnapshot

withPersistedPlanSnapshot
  :: RootInvocationAuthority scope brokerGeneration ProjectUp
  -> UnboundRunLease scope brokerGeneration
  -> ProjectPlan scope specDigest planId configId cfg
  -> (forall planDigest.
        VerifiedPlanSnapshot scope specDigest planDigest
        -> BoundPlanSnapshot scope specDigest planDigest planId
        -> PlanDigestBinding scope specDigest planDigest planId
        -> BoundRunLease scope specDigest planDigest brokerGeneration
        -> NormalActiveRecovery
             scope specDigest planDigest planId brokerGeneration
        -> IO a)
  -> IO (Either SnapshotError a)

withBoundPlanSnapshot
  :: RootInvocationAuthority scope brokerGeneration verb
  -> UnboundRunLease scope brokerGeneration
  -> VerifiedPlanSnapshot scope specDigest planDigest
  -> (forall planId.
        BoundPlanSnapshot scope specDigest planDigest planId
        -> PlanDigestBinding scope specDigest planDigest planId
        -> BoundRunLease scope specDigest planDigest brokerGeneration
        -> BoundInvocationRecovery
             scope specDigest planDigest planId brokerGeneration
        -> IO a)
  -> IO (Either SnapshotError a)

activateNormalBoundRevision
  :: NormalActiveRecovery scope specDigest planDigest planId brokerGeneration
  -> (forall activeRevisionVersion journalVersion requiredResourceSet.
        ActivePlanRevision
          scope brokerGeneration planDigest activeRevisionVersion
        -> AcquisitionJournal scope planId
        -> RehydratedResourceSet
             scope planDigest planId brokerGeneration requiredResourceSet
        -> ProjectOperationState scope planId journalVersion OpenProject
        -> RevisionPermitAuthority
             scope planDigest planId brokerGeneration
             activeRevisionVersion journalVersion
        -> CurrentBrokerSessionAdmission
             scope planDigest planId brokerGeneration
        -> a)
  -> IO (Either PlanMigrationError a)

activateRecoveredNormalBoundRevision
  :: NormalActiveRecovery scope specDigest planDigest planId brokerGeneration
  -> OldPermitFenceSet
       scope planDigest oldBrokerGeneration brokerGeneration
       requiredSessionSet requiredOperationSet
  -> VerifiedSessionOperationManifest
       scope planDigest oldBrokerGeneration requiredSessionSet requiredOperationSet
  -> ...
  -> IO (Either ReconcileError a)

currentGraph
  :: ProjectPlan scope specDigest planId configId cfg
  -> LifecycleGraph scope planId

recoveredGraph
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> LifecycleGraph scope planId

teardownPlan
  :: TeardownVerb verb
  -> LifecycleGraph scope planId
  -> AcquisitionJournal scope planId
  -> TeardownPlan scope planId verb

openTeardownForest
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> ActivePlanRevision
       scope brokerGeneration planDigest activeRevisionVersion
  -> ProjectOperationState scope planId journalVersion OpenProject
  -> RevisionPermitAuthority
       scope planDigest planId brokerGeneration
       activeRevisionVersion journalVersion
  -> TeardownPlan scope planId verb
  -> (TeardownForest scope planId verb -> a)
  -> IO (Either TeardownError a)

withRecoveredProjectFrame
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -> (RecoveredProjectFrame scope planId frame -> a)
  -> Either TeardownError a

authorizeHarnessClose
  :: HarnessCloseRoot projectId runId brokerGeneration
  -> ProjectModeLease
       projectId (HarnessMode runId) brokerGeneration
  -> BoundRunLease
       (Harness projectId runId) specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot
       (Harness projectId runId) specDigest planDigest planId
  -> ProjectOperationState
       (Harness projectId runId) planId journalVersion OpenProject
  -> ProjectClosureEvidence
       (Harness projectId runId) planId journalVersion
  -> (forall closeEpoch closeJournalVersion.
        ProjectOperationState
          (Harness projectId runId) planId closeEpoch ClosingProject
        -> HarnessCloseAuthority
             projectId runId planId brokerGeneration closeEpoch
        -> HarnessCloseJournal
             projectId runId planId brokerGeneration closeEpoch closeJournalVersion
        -> a)
  -> IO (Either TeardownError a)

harnessClosePlan
  :: HarnessCloseAuthority projectId runId planId brokerGeneration closeEpoch
  -> ProjectOperationState
       (Harness projectId runId) planId closeEpoch ClosingProject
  -> LifecycleGraph (Harness projectId runId) planId
  -> AcquisitionJournal (Harness projectId runId) planId
  -> HarnessClosePlan projectId runId planId brokerGeneration closeEpoch
```

`withProjectPlan` rejects missing parents, duplicate frame/resource identities, invalid handoff order,
or a mutating step without a teardown policy. Its constructor is hidden, and only a compatible
`LifecycleProfile scope` plus `ValidatedConfig scope specDigest configId (cfg scope)` and a
`NonEmpty (PlanDraft scope specDigest (cfg scope))` can produce the scoped steps,
topology, acquisition journal, and teardown projections. The rank-2 continuation creates a fresh
`planId`; neither a local journal nor a handle from another Production project/run can type-check with
this plan. `configId` is the exact validated root/frame config identity bound by the local decoder or
authenticated handoff. A narrowed child has different bytes and therefore receives a fresh child
`configId`; an opaque projection binding preserves scope and the stable plan revision rather than
pretending parent and child byte identities are equal.
An abandoned configful Production `ProjectUp` cannot obtain the unbound-only fresh profile.
Phase 10's protected recovery opener instead requires the exact new root/broker authority, active
Production mode, bound lease, verified/bound snapshot and binding, and `BoundInvocationRecovery`.
`withRecoveredProductionProjectPlan` accepts only its indexed recovery profile and reproduces only the
same `planId`/digest; incomplete/completed migration uses the separately typed recovered migration
builders. Harness and teardown recovery cannot inhabit that profile.

`renderSnapshot` is only a pure canonical value; it grants no authority.
Before the first `PreparedOperation`, `withPersistedPlanSnapshot` atomically commits and fsyncs that
versioned, non-secret resource graph, stable operation keys, and teardown policies in the protected root
store and binds the acquired lease to that exact digest in a protected compare-and-swap. It jointly
yields the verified snapshot, plan binding, local bound snapshot, exact `BoundRunLease`, and
`NormalActiveRecovery`; only `activateNormalBoundRevision` may then expose the active-revision proof,
live acquisition journal, complete freshly verified `RehydratedResourceSet`, versioned Open-project
state, permit authority, and current-broker session admission after proving every recorded older-broker
session Closed, including zero-operation sessions. An abandoned revision with a recorded Open session must instead use the exact-set
`activateRecoveredNormalBoundRevision` gate and old-permit fence proof plus the manifest pairing an
independent complete session set with its operation set. The protected gate internally rebinds and
closes each existing logical session—including a zero-operation Open session—and totally classifies
unknown, pre-call continuable, already-observed retryable, successful, and terminal operation records.
Intent registration atomically adds the operation to that exact session and advances the session/project
journal versions, so no orphan intent can fall outside the manifest. Acquisition registration consumes a
closed origin: either the sole no-prior-generation proof or `FreshGeneration` through
`freshAcquisitionIntent`; the registration compare-and-swap revalidates that exact origin while writing
the new generation and membership. An initial intent may validly have no fence record, but cannot
prepare. Recovery first idempotently resumes the sole stable initial-fence protocol and threads its
successor session/state/permit before exposing current-fence continuable authority. Only the five exact
pre-call/intermediate phases receive continuable prepare authority, and only the exact whitelisted observed
phases receive fenced same-key retry authority. It verifies/rebinds the complete resource-record set
before yielding resources or admission. Every prepare also consumes the exact plan-owned closed
precondition set, reruns all probes/versions, and jointly returns the only prepared operation/
preconditions pair accepted by the adapter. No mutating interpreter exists outside those continuations.

A later invocation verifies the stored snapshot and uses `withBoundPlanSnapshot` to bind it to a fresh
local `planId` and the new broker generation's exclusive lease. It receives
`BoundInvocationRecovery`, not a generic journal. Production first proves the operation state is Open;
Harness must choose between Open revision recovery and the exact persisted Closing epoch. The Open
branch then exhaustively chooses normal active, incomplete migration, or committed-new-but-not-activated
migration. Within the normal-active branch, only its matching activation gate yields
`AcquisitionJournal scope planId`; migrated activation and completed-migration recovery have their own
exact gates. Every journal is a freshly rebound local view of stable records, never a serialized
generative `planId`. The Closing branch can
resume only the old run's close journal. Unknown/incompatible snapshot versions refuse unless an
explicit migration validates them.

For a compatible revision, migration plan construction happens before freeze.
The sole `withProjectUpMigrationProfile` producer first revalidates the exact `ProjectUp` migration
root, active mode, old-bound lease/snapshot/binding, and normal-active recovery without requiring a new
plan. `withProspectiveMigrationPlan` consumes the resulting indexed profile and same old-bound package
with the new validated config and non-empty drafts and jointly creates one fresh candidate
`ProjectPlan` plus a pure, non-authorizing `ProspectivePlanSnapshot`/binding in a rank-2 scope.
`withPlanMigration` accepts only that exact candidate package. It persists/fsyncs the prospective
snapshot under a fresh `stableMigrationKey`, authoritatively reads back the exact bytes, and only then
freezes the old revision; failed or unknown persistence cannot revoke admission. A crash after
persistence but before freeze leaves only an unreferenced non-authorizing record, removable only after
proving no migration references it.

After persistence, the migration gate internally derives the exact old
`VerifiedResourceRecordSet`, atomically records the stable key while revoking session admission and
freezing operation preparation, and drains or authoritatively fences every issued old permit before
copying. Session opening and freeze contend on the same Open project-journal/revision version: the freeze cannot settle until every
independently enumerated session, including a zero-operation session, is Closed, while a retained
admission cannot open after freeze. A plan-owned fold pairs every manifest member with one complete
`VerifiedResourceRecordBundle`: owned disposition includes its receipt, while released disposition
includes only its tombstone and cannot become managed. Missing, duplicate, extra, unknown, or
disposition-mismatched records refuse. Freeze replaces the old bound lease with one
stable-keyed `FrozenMigrationRunLease`. `bindLiveMigrationPlanSnapshot` binds the already-built candidate
to the exact verified persisted snapshot; it cannot reconstruct or substitute a plan after freeze.
Incomplete recovery first loads that same prospective snapshot by the recovery record's stable key and
verifies its spec/plan digests before `withRecoveredMigrationPlanSnapshot` may reconstruct a fresh local
binding. Staged new records authorize nothing. One protected
compare-and-swap then consumes that exact frozen lease, changes the active lineage old→new, archives old
active records, returns only the new-bound lease, and yields one old/new-indexed
`PlanMigrationBarrier`; no path can retain both lease authorities.
`activateMigratedPlan` must consume the matching active revision, barrier, bound plan, and complete set
before any new permit. Activation also rechecks migration session settlement and yields the new
revision's `CurrentBrokerSessionAdmission`; neither configful nor configless completed recovery can open
a session without it. A pre-CAS restart resumes the frozen incomplete manifest; a teardown may instead
cancel its inactive staging while old remains active. A post-CAS restart selects completed recovery:
both configful and configless paths load the exact stable-keyed persisted prospective
`VerifiedPlanSnapshot` before constructing or binding any local plan. Configful `up` can rebuild only
when its config/drafts render those exact bytes; configless `down`/`destroy` uses the protected
snapshot-derived recovery plan. Current config never selects or infers the migration target. Old
binding/permits cannot reopen after the CAS, and no prospective/frozen/staged state grants effect
authority before activation.

Here `cfg` is a **scope-indexed config family**, not an independent concrete type: a
`ProjectPlan (Production projectId) specDigest planId configId cfg` necessarily contains
`cfg (Production projectId)`, while a
`ProjectPlan (Harness projectId runId) specDigest planId configId cfg` necessarily contains
`cfg (Harness projectId runId)`. A
production config, handle, journal, or receipt therefore cannot enter a harness plan, and two values that
merely share `Production` cannot mix across `planId`.

`DerivedTopology scope planId` is computed from the accepted steps and cannot be supplied or updated
independently. Each mutating step records its typed reconcile result/ownership receipt, and
`teardownPlan DownVerb` and `teardownPlan DestroyVerb` have distinct result types. Both can contain only
child-first operations authorized by the same plan's receipts. The durable root remains in the plan with
an explicit `Preserve` teardown policy: neither projection deletes it, while `Destroy` may remove
verified provider/runtime resources that `Down` must retain. A deploy step without a corresponding
topology edge or teardown policy is therefore not a valid
`ProjectPlan scope specDigest planId configId cfg`.

The pure `TeardownPlan` is not itself an effect cursor. `openTeardownForest` is the sole conversion: it
binds the projection to the exact protected snapshot, active revision, and matching Open-state/permit
version. The forest's exhaustive next-work eliminator yields `CompletedTeardownForest` or one closed
`TeardownAuthorizationPoint`; only its private eliminator exposes either a destroy-only pre-descent
reachability step or the plan-derived settled-child proof/cursor for one ordinary step. Callers cannot
wrap either branch. After `down`, the pre-descent step makes only the exact stopped provider
teardown-reachable; its successor forest exposes retained children, and their later settlement exposes
the provider's ordinary stop/delete step. Every attempted effect returns the successor forest even on
typed failure. `verifyDestroySettled` accepts only the completed Destroy forest.
Recovered ordinary step evidence is itself a closed sum derived from the bound snapshot, complete
rehydrated set, and exact forest step: the owned branch yields a managed handle/receipt, while the
released branch yields only its verified ordinary/adopted tombstone and matching bindings.
`confirmReleased` settles that branch without backend-call authority. Only an authoritative protected
absence recheck plus a distinct new acquisition key can turn the released branch into
`FreshGeneration`; a tombstone can never become a managed handle. `FreshGeneration` is only eligibility:
its sole exported consumer builds the exact acquisition origin, and the next intent-registration
compare-and-swap must consume/revalidate its release/absence version while atomically adding the new
generation to the session.

Harness terminal cleanup is not an out-of-band exception to that plan. After assertions, ordinary
`project destroy` settles all project resources but still preserves the run's durable root so
destroy→up checks within a variant remain meaningful. `verifyDestroySettled` is the sole producer of its
proof: it checks the complete plan-derived destroy forest, protected journal, terminal release
observations, absence of unresolved nodes/live prepared operations, and the complete Closed session set at the exact
current version. A true
pre-effect refusal instead goes through the sole `verifyNoProjectResourcesAcquired` verifier, which
checks that the bound snapshot has no resource operation/permit/fence/receipt/effect record and that
every registered session is Closed and empty. The two closed conversions to `ProjectClosureEvidence`
accept only those proofs; unresolved partial ownership produces neither. Only a narrow
`HarnessCloseRoot`, derived either from the still-live harness root or from an exact abandoned-run
recovery opener, can combine the project-wide Harness mode lease, exact
bound run lease, bound snapshot, versioned Open state, and same-version `ProjectClosureEvidence`.
`authorizeHarnessClose` atomically verifies all ordinary sessions Closed and changes Open to a fresh
Closing epoch while creating its close journal; a concurrent operation prepare and that CAS cannot both
win. `harnessClosePlan` is a third, harness-only projection of the same graph and journal. Its close
interpreter uses the normal durable unknown/reprobe/fence protocol to conditionally release the exact
owned generated config and `.test_data/<runId>` generations. Every terminal close observation returns
`HarnessCloseAdvance` on success or typed failure; its eliminator yields the only successor close
journal, so the prepare-time version cannot be reused or strand recovery. Only after every close outcome
and session is settled does one finalizer atomically record `ClosedProject`, close the bound lease, and
release the project-wide Harness mode last. Production has no constructor for this authority. A crash
after the close CAS or any close effect leaves the exact Closing epoch and close journal recoverable;
recovery never turns it back into Open or rehydrates general harness/`ProjectUp` authority. Before fresh allocation,
`recoverAbandonedHarnessRuns` must close every verified incomplete old lease and produce a protected
empty-set compare-and-swap proof, `ClosedAbandonedHarnessRuns`. Its separate rank-2 unbound/bound fold
callbacks are the only producers of each exact existential `VerifiedIncompleteRunLease`, and the sweep
rechecks terminal closure after each callback before advancing; callers cannot invent or skip an old
run. `withHarnessRoot` consumes that versioned proof atomically with allocation. Production and Harness
openers also contend on one
project-wide mode record, so a new run cannot begin by choosing another ID, racing the recovery sweep,
or slipping between Harness precheck and acquisition.

Production uses a separate closed `ProductionClosureAuthorization`: settled closure requires exact
`ProjectDestroy` root authority, while any verb may close only with the true pre-effect proof. The
Production finalizer revalidates that verb-safe authorization with the exact mode/lease/snapshot/state
and complete Closed-session set, then atomically records `ClosedProject`, closes the invocation lease,
and clears mode. Session opening advances and compare-and-swaps that same Open project-journal version,
so it and finalization have exactly one winner; no mode-cleared partial state exists. An `up`/`down`
partial teardown cannot be relabeled as settled destroy.

- `project up` interprets the current forward chain to bring up a **persistent stack**; current
  `project down`/`project destroy` run the verb's reverse projection of the one plan rather than recursively
  interpreting the whole plan. `--dry-run` renders the forward chain; `context` currently introspects
  projected frame data (see
  [§ Current Status](#current-status)).
- `test run` is a **driver** of that one representation, not a second one. For the demo it reads a
  `<project>.test.dhall` containing an informational suite list plus resource overrides; the case matrix is compiled
  in Haskell. Per generated configuration, it writes a
  `<project>.dhall`, runs the **real `project up`** over the project's own chain, runs the case assertions
  in the appropriate frame, and tears down with `project destroy`. The bring-up a test exercises is the
  same chain production uses. The demo currently hardcodes the Production cluster profile, showing that
  shared chain shape alone does not prevent profile/path drift.
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

The lift primitive has provider-backed folds for Incus, Lima, and WSL2, and the binary-context
gate is topology-aware (runtime configs carry provider-backed frames, a current frame, and locally
checked witnesses), and the canonical demo chain runs end-to-end. The core command tree is exactly
`project`, `test`, `service`, `context`, and `check-code` — a fixed surface with no per-project verbs. The
demo contributes its deploy as the substrate-selected pure value
`demoChainFor :: Substrate -> ProjectConfig -> [Step]` in `demo/src/HostBootstrapDemo/Commands.hs`, its
`web` and `accelerator` service variants, and its VM/provider IO inside the composite actions represented
by chain steps.

`Step`, `StepKind`, and `ProjectStepId` constructors are hidden. Smart constructors attach an explicit
reverse policy and namespaced operation key; core/project identities are disjoint even when presentation
labels match. `mkStepPlan` rejects duplicate identities, conflicting frame labels, non-contiguous frame
returns, and invalid post-handoff placement. Generated-sequence properties prove a valid list is
preserved exactly and an invalid `A, B, A` shape is rejected rather than regrouped.

`project up` is the recursive interpreter driven by the resolved `StepPlan`. The VM-backed demo branches
descend the 3-frame topology
(`host-orchestrator-0`, `vm-orchestrator-1`, `vm-project-container-2`); the direct native Linux GPU branch
uses a 2-frame metal → direct-project-container chain with no VM frame. `project down`/`destroy` are not
the same recursive interpretation: they run the verb's reverse projection, reaching only the frames this
binary can touch.
The finalized `ProjectSpec` still carries its one teardown projection beside the plan, so receipt-bound
child-first reverse traversal remains open; Phase 16.6 owns that consolidation.

`context` is read-only introspection (`inspect`/`path`/`show`/
`schema`/`render`), and `test init` writes `<project>.test.dhall` while `test run <case-id>|all` runs the
standardized harness.

The current `context-init` action body only announces a frame anchor. VM projection/streaming happens
inside the composite bootstrap action; the container projection is carried by the descent that same
`context-init` step declares (`descendsVia`), so the announcing node and the bytes the child receives
are one plan value rather than two independently supplied ones; and service config uses a ConfigMap. The
target plan additionally makes projection, authentication, durable preparation, and delivery one
operation. `deploy-kind`/`deploy-chart`
bring up the cluster and workload; `deploy-minio` creates registry backing before
`deploy-registry`/`push-image` install the in-cluster registry and push
the project image; `context inspect` renders the topology with the current frame marked.

A complete stack also includes MinIO and the selected accelerator daemon. Current native validation,
test-profile isolation, and durable destroy/up/readback remain plan-owned gates; see
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

The accelerator lifecycle includes `PostHandoff` hooks, a direct
Linux GPU `nvkind` host -> project-container topology, Apple/Windows host daemons have pid/config
start-stop scaffolding, and the daemon/web path uses CBOR WebSocket. Static/local socket and browser
specifications are implemented; closure still requires the live host/in-cluster substrate runs proving
the UI add operation reaches the daemon-built worker.

The harness's config handling is reconciled with the § W single-representation rule above. `test run all`
reads the thin `<project>.test.dhall`, generates each run's scope-indexed `<project>.dhall` through the
Harness request of the single restricted `psAssemble` and matching mapped codec, drives `project up`
against that generated config, and deletes it on teardown only while the exact bytes
still match; changed bytes remain in the reported locked quarantine. The
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
  interpreter, the host-management step kinds, the `ensure` kind, the execution-shape taxonomy, and the
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
- [run_models](run_models.md) — the four execution-shape names derived from the validated plan.
- [incus](../engineering/incus.md) and [cluster_lifecycle](../engineering/cluster_lifecycle.md) — the
  `InVM` frame and the fail-closed in-container cluster path.
- [harness_workflow](harness_workflow.md) — the `runMatrix` + `Seams` test engine that `test run all`
  drives, separate from the deploy chain.
- [composition_patterns](../engineering/composition_patterns.md) — the cookbook of shapes that instantiate
  this model.
- [authoring_project_binaries](../engineering/authoring_project_binaries.md) — how a consumer authors its
  additive step fragments and finalizes their `StepPlan`.
