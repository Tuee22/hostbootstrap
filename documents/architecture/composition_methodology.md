# Composition Methodology: The Chain Is The Project

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [binary_context_config](binary_context_config.md), [library_hierarchy](library_hierarchy.md), [run_models](run_models.md)

> **Purpose**: Define the foundational composition model of `hostbootstrap-core`: project fragments
> produce one opaque validated `StepPlan` authoring graph admitted into the indexed
> `ProjectPlan scope specDigest planId configId cfg`; the exact public Chain consumes that plan's
> forward/topology projections, and its pure reverse projection is derived from the same representation.
> Receipt-bound traversal and complete resource/effect authority remain downstream work. The same step
> algebra composes deployment and runtime business logic.

## TL;DR

- **The admitted project plan is the declared forward order.** A project binary contributes additive
  root/config-scoped `[Step]` fragments; `mkStepPlan` validates the authoring graph, and plan admission
  retains its exact non-empty `forward` projection. Validation preserves the exact order or rejects
  empty/duplicate/conflicting plans, including a non-contiguous `A1, B1, A2` return and a post-handoff
  suffix that does not unwind from the deepest participating frame toward the root, before effects. Each
  frame that has a successor declares exactly one descent on its own plan node, so topology is part of
  the same value. The indexed `ProjectPlan scope specDigest planId configId cfg` also derives a
  `TeardownPlan scope planId frame verb` from that admitted plan and its exact `CurrentFrame`: it retains
  stable step identities, operation keys, reverse policies, and callbacks, omits preserved nodes, and
  schedules only the current-frame suffix. The projection is pure and non-authorizing; receipt-bound
  traversal is a later layer (§ W).
- **The exact Chain is the current-frame foundation of the recursive, fractal interpreter.** `renderChain`
  consumes the admitted plan's complete `forward` projection. In the target rooted runtime, the root process
  is the sole lifecycle
  coordinator: it owns one `ProtectedStore`, global lease/snapshot/acquisition, recursive
  `RootedPlanCatalog`, and every frame journal. Children are long-lived storeless `FrameExecutor`s. For each
  node, the root durably prepares exact own/projected keys and signs a bounded response; the child
  exact-compares its locally reconstructed `ExecutionNode`, reifies the same-CAS gate through a hidden
  allow-listed mint, performs the local effect, and returns an observation for root settlement. Production
  dispatch retains or reconstructs the exact root plan through rendering and persistence; its Cabal-private
  root-Up `LifecycleEntry` alone derives durable authority. Rooted child execution and proof-complete
  traversal remain with the
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md);
  topology or command arguments alone mint no child admission. Descent is always the same shape:
  *provision the frame → build/install the `pb` in it → hand off `pb project up`*.
- **The wire is closed and lower-owned.** The
  [authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
  owns `RootedLifecycleRequest`/`RootedLifecycleResponse` v1 and the canonical `RecoveryChildPackage`. The
  hidden neutral request and exact nine-/eleven-field response codecs are implemented and exact-source-guarded
  without a semantic/process/durable importer; only neutral Receiver-internal folds serve transport. The
  implemented no-new-type facade exports the abstract response and renderer,
  fixed-domain live-broker signer, and installed-key CPS verifier; the opaque signed result remains descriptive
  rather than authority and has no semantic runtime caller. Implemented keyless transport carries exact
  singleton request/response bytes through the bounded sealed requester envelope, checks intermediate suffixes
  and root equality, and verifies the returned signature only at the originating typed operation.
  Recovery's rooted binding commits separately to the complete package payload and its child-config field; no
  adapter-only digest is relabelled as configuration. The lower carrier composes no package of its own. The
  recursive phase's catalog alone produces the package, admits its
  complete config/digest, and routes the exact Offer through the keyless relay to its installed root signer; it
  does not add ad hoc tags. Root signatures authenticate the root, while
  requester path/nonces/ordinals provide cooperating-interpreter routing and replay integrity, not malicious
  launching-parent identity. The root opens a frame session with no predecessor; four-field `OpenFrame`
  contains only its nonce and attaches using the sealed external root-nearest-to-leaf requester envelope. That
  envelope uses the same one-to-256-component, 4,096-byte-per-component grammar as the inner post-open path.
  Exact nine-field signed `Opened` discloses only the admitted canonical path plus opaque session/stage and next ordinal and
  contains no digest of itself. The root then hashes and durably reads back the complete signed response; that
  derived digest becomes the first predecessor for the next request. Only after that verified response can the
  storeless executor exist.
  Exact eleven-field post-open responses bind the complete request digest, echo path/session/nonce, carry the
  root-selected successor stage/ordinal, and admit only their closed request family. `Prepared` nests
  node/dependencies/operation-gate/projected-gates packages; `FrameComplete` carries the canonical report;
  `ReceiptRecorded` repeats its predecessor digest; rooted `Refused` is post-open only. The root alone signs
  catalog-selected prepared grants and settles observations.
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
frame. Project fragments declare lists; validation makes one opaque authoring graph, and admission turns
it into the exact public interpreter input:

```haskell
addSteps :: (forall scope rootId. CanonicalProjectRoot scope rootId -> cfg scope -> [Step]) -> ProjectSpecBuilder cfg tcfg -> ProjectSpecBuilder cfg tcfg
mkStepPlan :: [Step] -> Either StepPlanError StepPlan
forward
  :: ProjectPlan scope specDigest planId configId cfg
  -> NonEmpty (PlannedStep scope planId configId (cfg scope))
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
local host. The implementation boundary is layered:

| Layer | Owner | Contract |
|---|---|---|
| pure target/context data | [Dhall configuration and the generic project model](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md) | public `HostBootstrap.Lift.Context`; target records, context stack, same-root mount, and inner transport argv; no resolution or effects |
| generic self-reference dispatch | [Ensure reconcilers](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) | `HostBootstrap.Lift` reexports the context, resolves the outer host tool, folds nested commands, and streams config; no provider realization or Registry import |
| provider lifecycle realization | [Host providers and the self-reference lift](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) | Incus/Lima/WSL2/direct-host probes and lifecycle builders consume and reexport lower target/rendering data |
| network/registry additions | [Composition and network algebra](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md) | `reachLeaf`, blob leaves, and Registry-owned authenticated dispatch consume generic Lift |

These source boundaries and their gates remain Active in numerical phase order in the
[development-plan status table](../../DEVELOPMENT_PLAN/README.md). The target recursive interpreter then
operates over that stack:

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
3. At a frame boundary, **hand off**: launch `pb project up` inside the next frame as a storeless
   child. The root coordinator has already recursively projected that target into its `RootedPlanCatalog` and
   opened its frame session. The launch goes through a sanitized `LifecycleProcessRoute` rather than the
   ordinary lift argv, because the child's standard input and output are the protocol channel. The child
   attaches with `OpenFrame`, verifies the root-signed `Opened`, and only
   then constructs its `FrameExecutor`; it executes only nodes granted through the closed rooted
   request/response protocol. Durable record selection and settlement remain at the root.

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
VMs use provider stop, while kind clusters use `kind delete cluster`. The exact pure library route is

```haskell
teardownPlan
  :: ProjectPlan scope specDigest planId configId cfg
  -> CurrentFrame scope planId frame
  -> ProjectVerb verb
  -> TeardownPlan scope planId frame verb

openTeardownForest
  :: TeardownPlan scope planId frame verb
  -> Either TeardownError (TeardownForest scope planId frame verb)
```

The projection schedules only the admitted current frame and its descendants, visits frames deepest
first, reverses forward order within each frame, and omits every `PreserveOnReverse` node. It retains the
forward plan's stable step identity, operation key, reverse policy, and declared callback; action
selection is by `StepIdentity`, never presentation text. `openTeardownForest` is projection-only and
returns a forest whose progress, authorization branches, closed work packages, successors, completion, and
`SubtreeSettled` proof retain the projection's nominal `frame`. The unframed `DestroySettled` proof exists
only after the exact plan/current-frame package proves that subtree is the topology's unique root. Neither function accepts an acquisition
journal, ownership receipt, revision permit, or effect authority, and neither turns a declared callback
into authorized release.
Production `HostBootstrap.Command` retains or reconstructs the exact plan/current-frame pair and reaches
this projection directly. That plan-derived work is not exact teardown command authority; nested entry
fails closed until [the recursive-lifecycle-command
phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) supplies the operator/descent gates.

The [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
owns the rooted child-to-parent unwind. The root retains the only store, global lease and snapshot, recursive
catalog, every frame journal, and all prepare, settle, replay, completion, and receipt transitions. Children
return bounded observations through the closed rooted protocol; they never receive a durable cursor,
`CommandAuthority`, raw record key, or store operation.

The implemented reverse foundation preserves the frame phantom through `TeardownPlan`, `TeardownForest`,
closed `LocalWork`/`DescentWork`, completion, and `SubtreeSettled`. A private verb-tagged root intent
protocol records or resumes exact Down/Destroy source coordinates under root liveness. Durable Prepared and
Bound reverse-descent rows retain the exact plan-owned adapter and edge, support exact retry and token-free
rehydration, and expose no child execution authority. Canonical reports, semantic completion, root-resident
parent acknowledgement, keyless routing, finalized child projection, and inert planned-forward packaging are
also implemented lower substrate, but remain fail-closed without the rooted runtime adopter.

Recursive admission is implemented on that same footing. One shared VLC-free immediate-target kernel owns
descriptor, context, configuration, and target-plan validation for a single declared descent, and both the
inert planned-forward package and the recursive catalog delegate to it. `RootedPlanCatalog` joins the root's
finalized specification, invocation authority, plan, current frame, and root-resident lifecycle context,
rechecks root residency and the authority's installed project and store identity, and then admits each
declared edge in turn — each level's admitted target becoming the next level's parent — until a frame
declares no further descent. Entries are reachable only through rank-2 folds over the catalog itself, so
descent evidence cannot be held, forged, or reordered outside the recursion that produced it. The catalog
has no runtime caller yet, so it too remains fail-closed.

The storeless forward package sits directly on that recursion. One rank-2 catalog fold selects an edge by
exact parent and child frame: a child frame no entry names is missing, a child frame more than one entry
names is a duplicate, and a child frame reached from another parent is a sibling of the requested edge
rather than the edge itself. The selected entry is then rechecked against the parent level's own retained
plan — the retained parent frame must be that level's current frame, the plan must declare exactly the
retained raw route as its single descent out of that frame, and the frame's plan-owned projected node keys
must be the ones the entry retains — so coordinates, routes, or keys projected independently of this
catalog refuse before any continuation runs. `CatalogForwardHandoff` then rechecks the admitted child
against the evidence the entry itself retains: the child frame must be the target plan's own current frame
and its validated configuration's endpoint, the retained child plan digest must be both the digest that plan
still renders and the digest its binding carries, and the retained configuration and payload digests must
equal one another and the digest the canonical payload still hashes to. Its eight indices are nominal; it
retains no lifecycle context, parent plan, or specification index, and its one eliminator exposes only the
stripped route, binding input, and canonical payload under a fixed unit result. It has no process or command
call site, so it is fail-closed on the same footing as the catalog it comes from.

Launching that child is a separate closed decision from describing where it runs. The ordinary lift route in
the table above is free to keep a container's standard input open for an in-place configuration payload, to
carry plan-authored extra arguments, and to inherit whatever descriptors the host frame held; the rooted
lifecycle protocol travels on exactly those descriptors, so a route that does any of that is a channel
somebody else is also writing to. `LifecycleProcessRoute` is therefore derived from a catalog forward package
or a recovery package and its plan-owned lift route rather than assembled, and it renders exactly one
argument vector per provider: Docker keeps standard input attached and runs at `/`, while Incus, Lima, and
WSL run noninteractively at `/`, reaching root through noninteractive sudo where the guest's default user is
not already root. Its closed grammar refuses `ConfigDelivery`, container extra arguments, a container that
outlives its own exchange, and any derived name that reads as an option, a separator, or a descriptor
request, so the detach, TTY, attach, standard-input, entrypoint, working-directory, and signal overrides have
no path into the rendered vector. The child's command is the invocation's own closed verb under `project`,
rendered rather than accepted, and every rendered path is absolute and free of the mount delimiter.

Launching that route is one bracket's whole job. The owner resolves the route's host tool to an absolute
path through the installed configuration, spawns it into a new process group with private stdin/stdout pipes
and inherited stderr, hands those pipes to the relay for the exchange's lifetime, runs the fixed completion
operation for the edge's direction, and reaps. Everything that could leave something behind is in the
release path: group TERM, a fixed grace, group KILL if the group is still there, an unconditional wait, and
only then the pipes closed. It bounds the launch and the grace and nothing else — the relay bounds the frames
a peer owes immediately, and the wait between admission and the completed report belongs to the admitted
effect's own policy — and it treats neither EOF nor a zero exit as completion.

A route points in one direction only: down, at the child a frame is about to launch. It is not that frame's
own place in the conversation, and the distinction matters because a middle frame holds both at once — it is
a nested frame of the root and the parent of a deeper child — so a value carrying both edges would let a
frame open a session for the child it is spawning instead of for itself. Beside the route sits the one
startup step that has no other owner: a frame's own opening. It is admitted through the nested arm of that
frame's installed `RecursiveHandoffRuntime` — a root arm speaks for no authenticated frame and is refused
there — builds the four-field `OpenFrame` from a fresh nonce and nothing else, carries it through the frame's
own carrier to the root, and verifies the signed answer against the independently installed key and those
exact request bytes, admitting only an `Opened`. What it yields is that exact request and that exact signed
response rather than any decoded coordinate, so the storeless executor built from the pair still verifies
both for itself. Everything after the opening is the executor's: it already owns the root-selected path,
session, stage, ordinal, and predecessor and the closed post-open request families, so nothing else builds a
post-open request. The route spawns nothing; it is the description a process owner obeys.

The reverse direction now stands on the same admitted edge. Durable reverse-descent preparation takes the
canonical child configuration only from the catalog's own entry for exactly this parent and child frame and
the recovery adapter only from the plan's own reverse projection, then joins them through Phase 13's frozen
neutral constructor. The complete package is what the prepared record frames, what the binding input's
child-configuration digest names, and what the offer payload must equal, so an adapter-only reverse input can
no longer be persisted or offered. The package and child-configuration digests are derived and compared
separately and a conflation refuses. Both root reverse entries retain the catalog they were admitted under —
constructed by the same recursion the forward entry admits, and writing no durable manifest, which the Up
entry alone owns. The private relay's reverse route is that durable transition wrapped in the ordinary
four-field Offer exchange: it opens the complete package recoverably through the frame's own keyless link,
proves payload, token, and opened binding agree, records the Bound row, and only then routes the exact Offer
to the already-installed root signer and serves the existing challenge loop. The route accepts no payload
argument of its own, so an adapter alone is unrepresentable there rather than rejected, and a repeated
attempt recovers the binding and token the root already minted instead of opening a second edge.

Recovery sends the [authenticated-handoff
phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)'s canonical
`RecoveryChildPackage`, whose exact bytes contain both child configuration and adapter and whose binding
commits separately to the package payload and child configuration. Its standalone bound is 8 MiB; Relay and
Receiver impose a 7 MiB embedded Offer-payload sub-ceiling, while Protocol's authoritative 8 MiB total-body
check may still refuse the other fields and framing overhead. The root selects the catalog edge:
`EdgeAdmission` authenticates the complete config/digest, `RecoveryAdmission` independently authenticates the
extracted adapter, and the exact Offer is routed to the signer already installed behind the private relay.
A storeless executor verifies the authenticated root scope, exact package, root-signed prepared grant, and
local plan/node plus operation/projected-gate packages before any local teardown effect.

The target coordinator admits every planned or recovery edge into `RootedPlanCatalog` before launching a
sealed Process/Receiver bracket, opens one `RootedFrameSession` per exact frame, and issues
`PreparedNodeGrant` only after durable Unknown. Observations settle at the root, and terminal receipt follows
Published → signed `FrameComplete` → `ReceiptConfirm` → Received → signed `ReceiptRecorded`. Successful
reverse completion then terminalizes and rearms the durable root intent; failed-Up unwind uses the same
child-first driver while retaining its original failure as a distinct origin. The forest still carries every
frame level, and one memoized descent settles the deeper ones; the phantom index, rather than the forest's
contents, makes the boundary hold. Cleanup aggregates failures, and neither
verb places the plan's data path in its cluster-teardown removal set — `down`'s removal set is empty and
`destroy`'s holds only derived paths. The demo creates host
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
unrepresentable. The active composition-and-network boundary places `liftSubcommandWithAuth` in
`HostBootstrap.Registry`, which consumes the lower generic Lift; generic Lift imports no credential policy.
See
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
  the target authority handshake. The
  [authenticated-handoff-and-child-admission phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
  supplies the standalone signed `AuthenticatedRootScope` producer/verifier, and the unchanged four-field
  Offer plus private Relay/Receiver now adopt it. A root link mints one capsule, nested links copy the exact
  bytes, and the receiver verifies it with an independently installed key before key, binding,
  challenge/grant, or payload semantics. That private transport is not yet the live container call site. The
  same phase now also adopts the rooted binding and complete recovery package in the private receiver and
  implements the hidden neutral lifecycle-request and lifecycle-response codecs plus the exact-request,
  fixed-domain live-broker signer and installed-key CPS verifier. Those public response operations mint no
  authority; the implemented rooted relay adopter uses the fixed verifier only at its originating typed
  operation, while every hop remains byte-preserving and semantically keyless. The
  container binary then runs
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
`HostDaemon` execution shape in the [run-model taxonomy](run_models.md). Activation, config/secret
verification, and one-use lifecycle admission yield the sole initial Prereq cursor; the core-owned runner
privately drives Prereq → Acquire → Ready → Serve → Drain → Exit. The concrete bus/store/role primitives
are L1's delta.

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

## What A Node Reaches

A step's action receives the plan-minted `StepExecution scope planId` descriptor and never the plan
itself. The descriptor is therefore the whole of what a node may act on, and it is derived from the
validated plan rather than supplied beside it.

**Its own operation.** `stepExecutionOperationKey`, `stepExecutionFrame`, `stepExecutionPlanDigest`, and
`stepExecutionDependencyKeys` are the node's own identities and its exact ordered plan prefix.
`stepExecutionPreparedGate` is the `PreparedGate` the interpreter opened for that operation before running
the action — the same gate it settles against afterwards — so an adapter the action drives prepares the
node's own effect rather than a fabricated one.

**Operations projected from it.** A resource that *relates* others has an operation key derived from the
keys it relates: the provider guest alias is `<provider>/<share>/guest-alias`. That key is nobody's own,
so without a route to it no node could prepare the relation at all. A step claims one with
`projectsOperation`, and `mkStepPlan` admits exactly the shape

```text
<zero or more of the declaring step's dependency keys, in plan order>/<its own key>/<suffix>
```

with a non-empty separator-free suffix, claimed once across the plan and never colliding with a node's own
key. The declaring node is thus the **last** resource the key names — the only one that can perform the
relation, because every other resource the key names is already behind it in the plan. The guest alias is
claimed by the durable-share node, whose prefix carries the provider.

The interpreter registers each projection with its node, opens a gate for each in the same exclusive entry
that publishes the node's own unknown phase, and settles the ones the action took at the phase the node
itself settles at. `stepExecutionTakeProjectedGate` hands out each once; a key the plan did not place under
this node yields `Nothing`. A declared projection whose gate is never taken stays unsettled and the session
close refuses, so declaring a relation the node does not perform fails closed.

**Its dependencies' handles.** A prepared call's dependency snapshot consumes the dependency's `Managed`
handle, and a generative handle is never serialised (see [ownership_invariant](ownership_invariant.md)).
The interpreter opens one `ResourceCarrier scope planId` for the whole interpretation;
`carryManagedResource` accepts only a handle `completeReconcile`/`completePreparedUnchanged` produced, and
`withCarriedManagedResource` reads one back under fresh generative indices, for a key in this node's
prefix only.

**Its planned resources.** `withNodeResourceOfKind` resolves the node's own planned resource or one member
of its prefix under the closed `PlannedResourceKind` relation; `withNodeObservedResource` additionally
compares the planned resource's plan digest against the descriptor's; `plannedNodeOperation` plans an
operation on the node's own resource from the same edge set the plan-level route reads; and
`withNodeGuestAliasProjection` derives the alias from the node's own declared projection.

## Single Representation: The Chain Is The Representation

A project must have exactly **one lifecycle representation** (§ W). Forward order is now one opaque
`StepPlan`: typed core/project identities are disjoint, operation keys and dependency prefixes derive
from that plan, frame segments are exact and contiguous, and render/apply/frame traversal consume the
same value, and each frame's descent is a node of that same plan. The indexed `ProjectPlan` route now
derives forward steps, topology, and the pure reverse projection from one opaque validated plan. Its
public `PlannedStep` eliminators expose only stable identity, operation identity, reverse policy, and the
declared reverse callback; no raw step or hidden plan constructor crosses the facade. Production command
dispatch uses that exact plan, while the reverse effect remains a declared callback rather than a
receipt-bound transition.

The declarations below therefore mix implemented pure plan surfaces with explicitly target durable and
recursive-lifecycle surfaces:

```haskell
data ProjectPlan scope specDigest planId configId (cfg :: Type -> Type) -- constructor hidden
data ValidatedConfig scope specDigest configId config                    -- constructor hidden
data PlanDraft scope specDigest config
data PlannedStep scope planId configId config
data DerivedTopology scope planId
data CurrentFrame scope planId frame
data AcquisitionJournal scope planId brokerGeneration
data LifecycleCursor scope planId frame brokerGeneration verb phase
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

data ProjectVerb verb where
  ProjectUp      :: ProjectVerb VerbUp
  ProjectDown    :: ProjectVerb VerbDown
  ProjectDestroy :: ProjectVerb VerbDestroy
data TeardownPlan scope planId frame verb -- implemented pure projection
data TeardownForest scope planId frame verb -- implemented opener result
data CompletedTeardownForest scope planId frame verb
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
  -> CanonicalProjectRoot scope rootId
  -> ValidatedConfig scope specDigest configId (cfg scope)
  -> NonEmpty (PlanDraft scope specDigest (cfg scope))
  -> (forall planId. ProjectPlan scope specDigest planId configId cfg -> a)
  -> Either PlanError a

withRecoveredProductionProjectPlanInputs
  :: RecoveredProductionLifecycleProfile
       projectId recoveredSpecDigest planDigest planId brokerGeneration
  -> CanonicalProjectRoot (Production projectId) rootId
  -> FinalizedProjectSpec
       (Production projectId) candidateSpecDigest cfg
  -> ValidatedConfig
       (Production projectId) candidateSpecDigest configId
       (cfg (Production projectId))
  -> (ValidatedConfig
        (Production projectId) recoveredSpecDigest configId
        (cfg (Production projectId))
      -> NonEmpty
           (PlanDraft
              (Production projectId) recoveredSpecDigest
              (cfg (Production projectId)))
      -> a)
  -> Either PlanError a

withRecoveredProductionProjectPlan
  :: RecoveredProductionLifecycleProfile
       projectId specDigest planDigest planId brokerGeneration
  -> CanonicalProjectRoot (Production projectId) rootId
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

plannedStepIdentity
  :: PlannedStep scope planId configId config
  -> StepIdentity
plannedStepOperationKey
  :: PlannedStep scope planId configId config
  -> OperationKey
plannedStepReversePolicy
  :: PlannedStep scope planId configId config
  -> ReversePolicy
plannedStepReverseRun
  :: PlannedStep scope planId configId config
  -> Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)

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
  :: ProtectedStore
  -> InstalledProjectIdentity projectId
  -> (InvocationCloseKey -> IO result)
  -> (forall brokerGeneration specDigest planDigest planId.
        RootInvocationAuthority
          (Production projectId) brokerGeneration VerbUp
        -> ProjectModeLease projectId ProductionMode brokerGeneration
        -> BoundRunLease
             (Production projectId) specDigest planDigest brokerGeneration
        -> VerifiedPlanSnapshot
             (Production projectId) specDigest planDigest
        -> BoundPlanSnapshot
             (Production projectId) specDigest planDigest planId
        -> PlanDigestBinding
             (Production projectId) specDigest planDigest planId
        -> BoundInvocationRecovery
             (Production projectId)
             specDigest planDigest planId brokerGeneration
        -> IO result)
  -> IO (Either SnapshotError result)

-- The sole public plan-bound journal opener.
withAcquisitionJournal
  :: RootInvocationAuthority scope brokerGeneration verb
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> ProjectPlan scope specDigest planId configId cfg
  -> (AcquisitionJournal scope planId brokerGeneration -> IO a)
  -> IO (Either LifecycleError a)

-- Lifecycle.Mode is the public facade over the canonical cursor record.
withLifecycleCursor
  :: AcquisitionJournal scope planId brokerGeneration
  -> ProjectFrame scope specDigest planId configId frame
  -> ProjectVerb verb
  -> LifecyclePhase phase
  -> (LifecycleCursor scope planId frame brokerGeneration verb phase -> IO a)
  -> IO (Either LifecycleError a)

withCurrentLifecycleCursor
  :: AcquisitionJournal scope planId brokerGeneration
  -> ProjectFrame scope specDigest planId configId frame
  -> ProjectVerb verb
  -> (forall phase.
        LifecyclePhase phase
        -> LifecycleCursor scope planId frame brokerGeneration verb phase
        -> IO a)
  -> IO (Either LifecycleError a)

activateNormalBoundRevision
  :: NormalActiveRecovery scope specDigest planDigest planId brokerGeneration
  -> (forall activeRevisionVersion journalVersion requiredResourceSet.
        ActivePlanRevision
          scope brokerGeneration planDigest activeRevisionVersion
        -> AcquisitionJournal scope planId brokerGeneration
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

teardownPlan
  :: ProjectPlan scope specDigest planId configId cfg
  -> CurrentFrame scope planId frame
  -> ProjectVerb verb
  -> TeardownPlan scope planId frame verb

openTeardownForest
  :: TeardownPlan scope planId frame verb
  -> Either TeardownError (TeardownForest scope planId frame verb)

-- Target durable lifecycle views layered above the pure projection.
currentGraph
  :: ProjectPlan scope specDigest planId configId cfg
  -> LifecycleGraph scope planId

recoveredGraph
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> LifecycleGraph scope planId

-- Target recursive recovery/admission surface.
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
  -> AcquisitionJournal (Harness projectId runId) planId brokerGeneration
  -> HarnessClosePlan projectId runId planId brokerGeneration closeEpoch
```

`withProjectPlan` rejects missing parents, duplicate frame/resource identities, invalid handoff order,
or a mutating step without a teardown policy. Its constructor is hidden, and only a compatible
`LifecycleProfile scope` plus `ValidatedConfig scope specDigest configId (cfg scope)` and a
`NonEmpty (PlanDraft scope specDigest (cfg scope))` can produce the plan whose scoped steps, topology,
and later teardown projections share one identity. The acquisition journal is not a pure plan
projection: the effectful `withAcquisitionJournal` boundary additionally requires the exact root, bound
lease, bound snapshot, and digest binding. The rank-2 plan continuation creates a fresh `planId`; neither
a local journal nor a handle from another Production project/run can type-check with this plan.
`configId` is the exact validated root/frame config identity bound by the local decoder or
authenticated handoff. A narrowed child has different bytes and therefore receives a fresh child
`configId`; an opaque projection binding preserves scope and the stable plan revision rather than
pretending parent and child byte identities are equal.
An abandoned configful Production `ProjectUp` cannot obtain the unbound-only fresh profile.
The implemented existing-Production `withBoundPlanSnapshot` admission and
`withRecoveredProductionLifecycleProfile` refinement instead require the exact new root/broker authority,
active Production mode, bound lease, verified/bound snapshot and binding, and
`BoundInvocationRecovery`.
An independently repeated finalization remains nominally distinct even when it describes the same static
project; ordinary callers cannot pair that candidate specification/config directly with recovered evidence.
`withRecoveredProductionProjectPlanInputs` is the sole narrow restart bridge: a hidden token is issued only
when the recovered profile and candidate finalized codec retain the same specification digest, the hidden
config kernel independently rechecks that digest and preserves the existing `configId`, canonical config
digest, and decoded value under the recovered phantom, and drafts are regenerated from the candidate's
private finalized builder. `withRecoveredProductionProjectPlan` then accepts only those indexed recovery
inputs and reproduces only the same `planId`/digest after exact root-bound bytes and origin agreement;
incomplete/completed migration uses the separately typed recovered migration builders. Harness and teardown
recovery cannot inhabit that profile.

`renderSnapshot` is only a pure canonical value; it grants no authority.
Before the first plan-bound `PreparedOperation`, `withPersistedPlanSnapshot` persists, fsyncs, reads back,
and exactly verifies that versioned, non-secret resource graph, stable operation keys, and teardown
policies in one protected-store entry. After that entry closes, a separate protected lease
compare-and-swap binds the acquired lease to the exact digest. These are ordered durable transitions, not
an atomic multi-record transaction. Full success jointly yields the verified snapshot, plan binding,
local bound snapshot, exact `BoundRunLease`, and `NormalActiveRecovery`.

The implemented `withAcquisitionJournal` next compares all retained evidence and, in one entry in the
lease's store, rereads the live mode/epoch, exact bound-lease record version/state/bytes, and protected
canonical snapshot before Session opens or resumes the dedicated record. Its store-local key is
`acquisition.<project>.<run>.<brokerEpoch>`; stable scope, local `planId`, digests, root verb, lease
version, and retained source-seed phase stay out of the key. The immutable stable binding is
collision-checked in the strict 13-field payload; `planId` is never serialized, and the recognized phase
is decoded as the initial cursor seed. A fresh record begins at `Prepare`; exact pre-handoff resume
preserves the phase and record version without writing. After handoff the acquisition row remains exact
and unchanged; only each frame's cursor-row phase is current/mutable. The user continuation runs after the
protected entry closes.

The [step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)'s
canonical cursor record and admission/transitions form the frame-local continuation of that admission, not
a second plan or topology representation. `Lifecycle.Mode` owns its
public facade; `Lifecycle.Session` owns the strict durable codec and protected CAS. One row is derived from the canonical length-framed acquisition key and
semantic UTF-8 frame id, and its payload binds the exact source key/version/bytes, frame, immutable root
verb, and current phase. The acquisition row's phase seeds an absent cursor row only. Once the
absent-to-present CAS lands, that frame's cursor row is authoritative; other frames have separate rows and
advance independently. Every open and successor rereads the unchanged canonical source at its exact
version and bytes.

Recovery uses `withCurrentLifecycleCursor`, whose rank-2 continuation receives the closed authoritative
phase and its matching cursor together. The only successors are `Prepare -> Execute -> Teardown`; there is
no terminal or verb-changing successor. A reservation/successor CAS is at-most-once, but callback delivery
after the protected entry unlocks is at-least-once. Exact resume, concurrent readers, or a callback
exception can therefore redeliver the same durable cursor without reserving a second transition. This is
the local restart boundary; it does not claim exactly-once backend effects or proof-complete recursive
child traversal.

This plan-bound acquisition row is separate from the
[sessions, journal, and fences phase](../../DEVELOPMENT_PLAN/phase-10-sessions-journal-and-fences.md)'s
`project.<planDigest>` Open/Closing transaction and from per-operation attempt/ownership records. The
future `activateNormalBoundRevision`
higher-order composition may expose the already-admitted journal together with the active-revision proof,
complete freshly verified `RehydratedResourceSet`, versioned Open-project state, permit authority, and
current-broker session admission after proving every recorded older-broker session Closed, including
zero-operation sessions; it is not a second raw journal producer. An abandoned revision with a recorded
Open session must instead use the exact-set
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

That ordering is the contract for the plan-bound route, not a property granted by the lower public
`openProjectJournal`, operation-session, or prepare primitives. Those primitives are non-authorizing:
proof-complete plan-bound callers still must pass through `withAcquisitionJournal`.

A later invocation verifies the stored snapshot and uses `withBoundPlanSnapshot` to bind it to a fresh
local `planId` and the new broker generation's exclusive lease. It receives
`BoundInvocationRecovery`, not a generic journal. Production first proves the operation state is Open;
Harness must choose between Open revision recovery and the exact persisted Closing epoch. The Open
branch then exhaustively chooses normal active, incomplete migration, or committed-new-but-not-activated
migration. After exact fixed-identity plan reconstruction, `withAcquisitionJournal` resumes the matching
`AcquisitionJournal scope planId brokerGeneration`; conflicting stable evidence reaches the same key and
refuses. Planned normal/migrated/completed activation gates must consume or internally compose that exact
admission while adding their own revision and resource proofs, never open an unguarded lower route. Every
journal is a freshly rebound local view of stable records, never a serialized generative `planId`. The
Closing branch can
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
independently. `teardownPlan ProjectDown` and `teardownPlan ProjectDestroy` have distinct result types and
derive their nodes only from `forward plan`, the plan's topology, and the exact `CurrentFrame`. Each
reverse node carries the same stable `StepIdentity` and `OperationKey` as its forward node. The durable
root remains in the plan with an explicit `PreserveOnReverse` policy and is absent from both projections;
the canonical admitted verb selects the action for the remaining nodes by typed identity. A total
`teardownPlan ... ProjectUp` retains that exact verb/digest/frame but contains no reverse nodes, and its
opener returns `TeardownProjectUpHasNoReverse` before considering the empty-plan error. The retained
reverse callback is still just the callback declared by that planned step.

The pure `TeardownPlan` is not an effect cursor. `openTeardownForest` consumes that projection alone,
rejects an empty projection, and returns `TeardownForest scope planId frame verb`; it does not accept or inspect
a protected snapshot, acquisition journal, active revision, Open-state version, permit, ownership
receipt, or effect capability. The opening `frame` index remains nominal through every current forest
successor, authorization branch, local/descent work package, completion, and `SubtreeSettled`. Production
can run retained callbacks in projection order from the exact plan/current-frame pair, but that does not
turn them into receipt-authorized transitions.

The implemented exhaustive `TeardownWork` eliminator classifies ordinary work from that already
frame-indexed forest. Its `LocalWork` branch alone exposes the key, action, policy, and runner accepted by
the local reverse interpreter; its existential `DescentWork` branch exposes only the exact immediate
parent/child topology edge. Branch-specific attempts retain the originating forest, and the public driver
classifies work internally before invoking separate pre-descent, local, or descent handlers. A local or
pre-descent result advances only its originating forest. Descent has no raw-success route: its handler must
return the exact existential child `SubtreeSettled`, whose ordered observations are validated and
bulk-imported, while failure keeps the whole child continuation outstanding. A later
durable admission layer binds each authorization point to the exact protected snapshot,
active revision, matching Open-state/permit version, journal state, and ownership evidence. Under that
target, the current private eliminator exposes either a destroy-only pre-descent reachability step or the
plan-derived settled-child proof with one closed ordinary-work package. After `down`, the pre-descent step makes
only the exact stopped provider teardown-reachable; its successor forest exposes retained children, and
their later settlement exposes the provider's ordinary stop/delete step. Every attempted effect returns
the appropriate successor/failure value, and `verifySubtreeSettled` accepts only the exact completed
frame-bound forest.

In that receipt-aware target, recovered ordinary step evidence is a closed sum derived from the bound
snapshot, complete rehydrated set, and exact forest step: the owned branch yields a managed
handle/receipt, while the
released branch yields only its verified ordinary/adopted tombstone and matching bindings.
`confirmReleased` settles that branch without backend-call authority. Only an authoritative protected
absence recheck plus a distinct new acquisition key can turn the released branch into
`FreshGeneration`; a tombstone can never become a managed handle. `FreshGeneration` is only eligibility:
its sole exported consumer builds the exact acquisition origin, and the next intent-registration
compare-and-swap must consume/revalidate its release/absence version while atomically adding the new
generation to the session.

Harness terminal cleanup is not an out-of-band exception to that plan. After assertions, ordinary
`project destroy` settles all project resources but still preserves the run's durable root so
destroy→up checks within a variant remain meaningful. `verifySubtreeSettled` checks the complete
frame-bound projection and exact ordered terminal observations, preserving Released, ForeignRetained, and
Refused. `verifyDestroySettled` is the sole producer of unframed project-wide proof: it additionally checks
the exact plan/current-frame package, unique topology root, digest, and full-root terminal sequence. The
later closure conversion independently checks the bound lease and complete Closed session set. A true
pre-effect refusal instead goes through the sole `verifyNoProjectResourcesAcquired` verifier, which
checks that the bound snapshot has no resource operation/permit/fence/receipt/effect record and that
every registered session is Closed and empty. The two closed conversions to `ProjectClosureEvidence`
accept only those proofs; unresolved partial ownership produces neither. Only a narrow
`HarnessCloseRoot`, derived either from the still-live harness root or from an exact abandoned-run
recovery opener, can combine the project-wide Harness mode lease, exact
bound run lease, bound snapshot, versioned Open state, and same-version `ProjectClosureEvidence`.
`authorizeHarnessClose` consumes that exact Harness closure evidence, accepts only settled destroy,
atomically verifies all ordinary sessions Closed, and changes Open to a fresh Closing epoch while creating
its close journal. Persisted Closing therefore proves ordinary destroy had already settled; a concurrent
operation prepare and that CAS cannot both
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

- `project up` interprets the current forward chain to bring up a **persistent stack**. Production
  `project down`/`project destroy` retain or reconstruct the exact plan and run its current-frame reverse
  projection, but that projection is not an authenticated recursive forest or exact teardown command
  authority. `--dry-run` renders the exact admitted plan; `context`
  currently introspects projected frame data (see
  [§ Current Status](#current-status)).
- `test run` is a **driver** of that one representation, not a second one. For each generated configuration,
  current Harness retains one exact Harness-scoped plan and drives the same hidden fixed root-Up entry plus
  the exact current-frame reverse boundary around assertion-only code; it neither shells `project up` nor claims recursive
  child entry. Production consumes the same plan/step algebra through its own current-frame command path.
  The recursive-lifecycle-command phase owns recursive Production traversal, root catalog/frame-journal
  integration, and the storeless executor boundary.
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
- **RIGHT**: every host and workload action is a step contributed into the one `[Step]`. In the target,
  `project up` interprets it frame by frame and the Harness consumes the same authenticated recursive
  machinery under its own scope rather than re-expressing lifecycle actions. Current Production and Harness
  share the exact current-frame Chain/reverse boundaries; Production fails closed at descent, while Harness
  invokes those boundaries directly around assertions.

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
returns, and post-handoff suffixes outside deepest-frame-to-root unwind order. Generated-sequence
properties prove a valid list is preserved exactly and an invalid `A, B, A` shape is rejected rather than
regrouped.

The public exact Chain is driven by the admitted `ProjectPlan`, matching Execute `CommandAuthority` and
`LifecycleCursor`, and the plan's `DerivedTopology`; every protected transition rereads the exact cursor
source/current row. Production dispatch consumes that boundary directly and retains one plan identity.
The VM-backed demo branches declare a 3-frame topology
(`host-orchestrator-0`, `vm-orchestrator-1`, `vm-project-container-2`); the direct native Linux GPU branch
declares a 2-frame metal → direct-project-container chain with no VM frame. Nested Production entry
currently refuses before effects, so complete traversal of either declared suffix remains
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) work.

The indexed reverse API is now exact at its pure boundary. `teardownPlan` consumes
`ProjectPlan scope specDigest planId configId cfg`, `CurrentFrame scope planId frame`, and the typed verb;
it projects that frame and its descendants deepest-first, reverses each frame's forward nodes, preserves
stable step/operation identities, and excludes `PreserveOnReverse`. The public plan facade exposes the
needed `PlannedStep` identity, reverse-policy, and callback projections without exposing its hidden
representation. `openTeardownForest` consumes only the resulting
`TeardownPlan scope planId frame verb` and returns
`TeardownForest scope planId frame verb`; every progress, authorization branch, closed work package, successor,
completion, and `SubtreeSettled scope planId frame verb` value retains the same nominal opening frame.
Only the unique-root destroy refinement mints unframed `DestroySettled scope planId`.

The Production `project down`/`destroy` command path drives this exact projection from its retained or
reconstructed plan/current-frame pair. Neither that consumer nor the pure opener binds reverse work to an
ownership receipt, journal state, exact teardown authority, or effect capability. The total local/descent
work split is implemented; authenticated child admission and proof-complete child-to-parent settlement
remain the target owned by the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

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
Harness request of the single restricted `psAssemble` and matching mapped codec, retains the matching
Harness-indexed plan, and directly drives its current-frame forward/reverse boundaries around assertions.
It unlinks the generated config on teardown only while the file's bound kernel identity and its recorded
payload both still match; anything else is a reported conflict and is left intact. A found foreign config
is therefore refused rather than treated as harness input. See
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md) and
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

- **L0 — `hostbootstrap-core`**: the composition algebra, the Step interface, the exact current-frame Chain
  plus target recursive `project up` substrate, the host-management step kinds, the `ensure` kind, the execution-shape taxonomy, and the
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
