# Composition Methodology: The Chain Is The Project

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [binary_context_config](binary_context_config.md), [library_hierarchy](library_hierarchy.md), [run_models](run_models.md)

> **Purpose**: Define the foundational composition model of `hostbootstrap-core`: project fragments
> produce one opaque validated `StepPlan` authoring graph admitted into the indexed
> `ProjectPlan scope specDigest planId configId cfg`; the exact public Chain consumes that plan's
> forward/topology projections, and its pure reverse projection is derived from the same representation.
> Receipt-bound traversal and prepared resource effects consume that exact plan. The same step
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
  consumes the admitted plan's complete `forward` projection. The implemented root-Up entry uses the
  root-only Chain path without loading a signing key, or, when its catalog has descendants, becomes the sole
  lifecycle coordinator: it owns one `ProtectedStore`, global lease/snapshot/acquisition, recursive
  `RootedPlanCatalog`, and every frame journal. Children are long-lived storeless `FrameExecutor`s. For each
  node, the root durably prepares exact own/projected keys and signs a bounded response; the child
  exact-compares its locally reconstructed `ExecutionNode`, reifies the same-CAS gate through a hidden
  allow-listed mint, performs the local effect, and returns an observation for root settlement. Production
  dispatch retains or reconstructs the exact root plan through rendering and persistence; its Cabal-private
  root-Up `LifecycleEntry` alone derives durable authority. Before Chain starts, the coordinator opens every
  catalog child session root-first. Chain's descent continuation selects only the exact catalog edge and
   policy-validating process route whose crossing argv is derived by the sole Lift fold; rooted requests dispatch only to the matching retained session. A nested child
  repeats the immediate-target projection through a keyless link and receives neither catalog nor root
  authority. Terminal reporting remains fail-closed until exact settlement evidence exists. Rooted child
  execution and proof-complete traversal remain with the
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
  until a rooted session or executor verifies its exact request and response coordinates. Implemented keyless transport carries exact
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
  `<project>.dhall` describes, and known mismatches fail fast. Those fields are descriptive; authenticated installed evidence supplies authority. The chain is a pure function of root parameters, so the shape lives in code and the
  `.dhall` carries only parameters, context, and witnesses.
- **The Step algebra is the reuse unit.** The core ships host-management step kinds (`deploy-vm`,
  `ensure-X`, `copy-source`, `build-pb`, `build-image`, `context-init`, `deploy-kind`, `deploy-chart`,
  `expose-port`, `post-handoff`); the project contributes workload step kinds (`deploy-minio`,
  `deploy-registry`, `push-image`, accelerator-daemon placement, …) into the *same* `[Step]`. Host and workload steps interleave freely — this is the
  workload-extension seam.
- **The VM producer is exact through Ready.** The demo's one `deploy-vm` adopter selects the closed Incus or
  Lima strong backend, consumes the interpreter-supplied `StepExecution`, resolves its provider resource by the
  execution's opaque operation key, and derives observation, provision, and Ready gates from the same prepared
  journal fence. Only managed Ready settlement is carried with its reverse identity and registered as a pending
  invocation-local provider dependency package. The package contains commitments and a bounded route rather
  than a managed handle or readiness witness; later lexical recovery freshly re-probes the exact retained
  backend. Registration follows settlement, so every refusal and provisional branch leaves the dependency
  registry unchanged.
- **The Direct producer reserves; it does not deploy a VM.** Its plan-declared provider resource is attached
  to the current metal-frame build node. That node receives its own `StepExecution`, admits the canonical host
  root and configured base-image egress through the Direct backend, and uses the same provision/Ready/carry/
  register sequence before CUDA, image construction, or nvkind work. Its carried operation is `reserved`, so
  later reverse work may terminalize the exact journal reservation but cannot claim a physical stop or delete.
- **A VM share is its own exact node.** `copy-source` follows the VM producer and precedes its descent. The
  node freshly recovers the package-bound Running provider, resolves its plan-owned durable-share resource,
  prepares from a live dependency probe, calls and settles the provider share backend, and keeps the managed
  share lexical through mount/alias work. Its host source is the canonical durable root and its guest target is
  the unchanged provider projection. Incus may attach and activate the share through its owned instance row;
  Lima re-probes the writable create-time mount retained by its exact backend. Returning closes the
  continuation; neither execution packages nor the generic carried-resource channel contain the
  provider/share handles.
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
| `ensure` reconciler | probe-first local install/verify; managed lifecycle authority is separate | the local host frame | L0 |
| `deploy-vm` | provision a provider VM (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows) | the host's VM provider | L0 |
| `copy-source` / `build-pb` / `build-image` | stage source, build the `pb`, build the project image | the current frame | L0 |
| `context-init` | announces the same plan node whose declared descent binds child projection and authenticated delivery | the current frame | L0 |
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

These source boundaries and their gates are tracked in numerical phase order in the
[development-plan status table](../../DEVELOPMENT_PLAN/README.md). The recursive interpreter then
operates over that stack:

1. Read the sibling `<project>.dhall`, verify the current frame, and select the steps belonging to it.
2. Run those steps in order. Config-free reconcilers remain local probe/install helpers. A managed
   resource operation instead receives its opaque scoped transition descriptor. The plan internally traverses the descriptor's complete edge set against the exact
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

`project up` reconciles managed resources through exact prepared adapters. Convenience `IO ()` actions
report completion only and do not mint readiness or ownership evidence. `project up --dry-run`
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
Production `HostBootstrap.Command` retains or reconstructs the exact plan/current-frame pair. That
plan-derived work is not exact teardown command authority; the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
supplies the operator/descent gates used for nested entry.

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
also implemented lower substrate. A prepared reverse descent now opens only its retained child projection,
and its rooted service retains the exact Offer and advances one forest through root-owned pre-descent,
child-executed local settlement, completed deeper descent, canonical close, and acknowledged receipt.

Recursive admission is implemented on that same footing. One shared VLC-free immediate-target kernel owns
descriptor, context, configuration, and target-plan validation for a single declared descent, and both the
inert planned-forward package and the recursive catalog delegate to it. `RootedPlanCatalog` joins the root's
finalized specification, invocation authority, plan, current frame, and root-resident lifecycle context,
rechecks root residency and the authority's installed project and store identity, and then admits each
declared edge in turn — each level's admitted target becoming the next level's parent — until a frame
declares no further descent. Entries are reachable only through rank-2 folds over the catalog itself, so
descent evidence cannot be held, forged, or reordered outside the recursion that produced it. The catalog
is admitted and persisted by the root lifecycle entry before frame sessions or child effects begin.

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
no path into the rendered vector. The child's command is the fixed coordinate-free
`--hostbootstrap-lifecycle-child` entry marker; the authenticated Offer is the sole source of its verb.
Every rendered path is absolute and free of the mount delimiter.

Launching that route is one bracket's whole job. The owner resolves the route's host tool to an absolute
path through the installed configuration, spawns it into a new process group with private stdin/stdout pipes
and inherited stderr, hands those pipes to the relay for the exchange's lifetime, runs the fixed completion
operation for the edge's direction, and reaps. Everything that could leave something behind is in the
release path: group TERM, a fixed grace, group KILL if the group is still there, an unconditional wait, and
only then the pipes closed. It bounds the launch and the grace and nothing else — the relay bounds the frames
a peer owes immediately, and the wait between admission and the completed report belongs to the admitted
effect's own policy — and it treats neither EOF nor a zero exit as completion.

The same bracket may install one provider reprobe endpoint by narrowing its existing `BrokerLink` for the
duration of the lexical provider kernel and child process. The child-side client uses only the authenticated
duplex already retained by its `ReceivedEdge`: one request is outstanding, each of at most 64 nonces is
consumed once, and only the exact request identity, closed response tag, canonical package commitment, nonce,
and observation/refusal are accepted. A nested parent forwards those field bytes unchanged through its own
keyless parent link, so arbitrary depth repeats the same edge-local operation and no intermediate frame gains
a root key, provider handle, package interpreter, or result-minting authority. The upstream response wait is
bounded to one second; frame and codec ceilings bound size. Closing either surrounding bracket removes the
only service path, and no socket, environment, argument, config, or durable-file substitute exists.

A child whose admitted plan contains cross-frame dependencies queries that endpoint only after its config,
plan, current frame, and immediate edge have all been authenticated. The query carries no candidate package:
the Process-owned parent answers with its exact carried provider package or explicit absence. A present
provider-domain package and its hidden nonce client are seeded into the child's one invocation-wide carrier
before the frame executor opens, so all local step runtimes see the same canonical/live pair and a deeper
descent can relay it unchanged. This is carriage, not refinement: no probe runs and no Running provider,
managed handle, readiness proof, receipt, or channel enters plan/config bytes or the carrier.

That carrier is invocation-local and directional: a package seeded into a deployment child is not promoted
back into its parent when the child frame closes. A later parent-frame step that needs a runtime fact must open
the owning frame again. Cluster exposure readback does this with one bounded frame-child transaction through
the selected provider lift; the far frame opens the durable exposure row and re-observes the exact relay before
returning only its loopback port. This is fresh observation, not upward carriage of the child's live package.

The fixed cluster node is the first consumer of that carriage. It selects the one provider package named by
its authenticated plan prefix, rebinds the carried provider receipt, and asks the parent-serviced nonce route
for a fresh generation; it does not rediscover the parent's backend in the child. Its opaque `StepExecution`
then supplies the cluster resource, provider edge, plan/config digest, profile, project root, and frame used to
form the action-side plan-owned package. The one call site writes only its canonical rendered bytes, discovers
the closed Kind/nvkind backend, reconciles and carries ownership, applies the exact cordon, settles a fresh
readiness observation, and finally registers the pending cluster-domain package and separate live service.
No sibling `ProjectPlan`, independent driver/name/path, raw tool invocation, or readiness flag participates.

At the far end, the fixed lifecycle-child marker enters the private receiver before ordinary command
parsing or sibling-config loading. The receiver loads the independently installed public key from
`<executable>.handoff.pub`. A forward package authenticates its exact canonical config wire; a recovery
package independently decodes and canonically re-renders its child config, reconstructs the digest-bound
child plan, and byte-compares the supplied reverse adapter with that plan's exact Down/Destroy projection.
Both arms then open one storeless `FrameExecutor`. Each root-signed `Prepared` response is matched to the
exact plan work before a local effect runs. A reverse `Descend` advances only when its signed body contains
canonical observations that replay to the exact retained child subtree. The child returns observations
through the rooted protocol, confirms the root's terminal receipt, and never opens the protected store or
settles a durable row.

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
the recovery adapter only from the plan's own reverse projection, then joins them through the [authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)'s frozen
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
local plan/node plus operation/projected-gate packages before any local teardown effect. Its reverse arm
reuses the same request pairing, ordinal advancement, settlement request, close, and receipt-confirmation
loop as forward execution. It cannot construct semantic completion: the bytes it finally hands to Receiver
are the exact report carried by the root's signed `FrameComplete`, and success waits for the matching signed
`ReceiptRecorded`.

Prepared reverse process launch preserves that lineage without exposing package bytes. The private teardown
owner canonically decodes the exact `RecoveryChildPackage` retained in `ReverseDescent` and releases it only
with the plan-owned lift context, binding input, and closed verb. A witness-only route kernel fixes the opaque
route's scope and broker indices to that same prepared lineage; the process owner then derives and launches
the sanitized route inside one lexical continuation. The witnesses are empty proxies, not authority, and raw
package bytes, argv, tools, or route constructors never reach the coordinator.

The reverse broker link is deliberately narrower than the general root link: config opening and activation
signing are closed refusals, while recoverable opening, recovery signing, rooted requests, and lifecycle
acknowledgements remain. Grant first retains the exact Offer in the prepared frame service. That service
derives the child terminal origin from the same prepared lineage and binding, publishes only the canonical
completed report, and retains verified `SubtreeSettled` through receipt. After the child transmits that exact
report, the existing process owner validates Bound and durably adopts it before returning. A mismatched Offer,
observation, descent result, report, or receipt advances no forest.

The root command frame and a descent's parent frame are separate nominal coordinates. A prepared reverse
descent existentially retains the root lifecycle context, teardown cursor, and command authority while its
public indices name the selected parent/child edge in that same root plan. Preparation therefore validates
the command against the root context and independently validates the edge against topology and the recursive
catalog. Deeper descent neither forges a child command authority nor coerces the root frame into its parent.

Production `project down` and `project destroy` now enter that machinery at one call site. The reverse-entry
producer reconstructs the committed target plan, retains the target lease, and lends the command driver an
opaque entry plus a terminalization continuation. The driver opens the plan forest once, executes siblings in
its declared order, and maps every descent to one prepared session/service/process bracket. A parent receives
only the `SubtreeSettled` value retained after the child's signed close, receipt, Bound verification, and
durable adoption; a process exit or an unverified report cannot advance the forest. The terminal continuation
first verifies that all rooted sessions for the retained plan digest are closed and only then consumes the
settled root proof under the retained lease.

The local reverse callback receives that reconstructed `ProjectPlan` together with its opaque `LocalWork`.
For a chart node, the operation key projects exactly one plan-owned chart resource; the command derives the
protected-record key from the stable plan digest, frame, and resource identity, verifies those same coordinates
against the canonical record bytes, and only then derives the Helm release and namespace from the chart.
Missing ownership is retained as foreign, malformed or mismatched ownership fails before mutation, and a
verified released tombstone is already converged. Chart cleanup therefore precedes cluster cleanup by the
forest's ordinary child-first/reverse-forward order without reconstructing a forward execution package.

A failed forward run has a deliberately narrower authority shape. Hidden
`FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId` can be produced only from the sealed
root Up entry, that entry's catalog, and either a receipt-recorded rooted `forward/failed` report or the
canonical root-local failed report published from the same live broker. The producer independently rejoins
project, broker generation, catalog record identity, root plan digest, report binding, and every reported
operation with the frozen reached prefix. It freezes both reached order and its unresolved subset and rejects
duplicates or an unresolved operation that was never reached. Its only operational fold returns the frozen
unresolved cleanup order. It exposes no store, Mode transition, root-authority constructor, or Destroy verb,
and exact retry must reproduce every retained report and reachability coordinate.

The coordinator admits every planned or recovery edge into `RootedPlanCatalog` before launching a
sealed Process/Receiver bracket, opens one `RootedFrameSession` per exact frame, and issues
`PreparedNodeGrant` only after durable Unknown. Observations settle at the root, and terminal receipt follows
Published → signed `FrameComplete` → `ReceiptConfirm` → Received → signed `ReceiptRecorded`. Successful
reverse completion then terminalizes and rearms the durable root intent; failed-Up unwind uses the same
durable Prepared/Bound child-first recovery driver while the Up command and cursor remain at Execute. The
forward failure and reverse unwind publish separate canonical terminal records; cleanup failure does not
replace the retained original error. The forest carries every frame level, and each exact child must produce its matching subtree settlement;
a memoized raw result cannot settle a deeper frame. Cleanup aggregates failures, and neither
verb places the plan's data path in its cluster-teardown removal set — `down`'s removal set is empty and
`destroy`'s holds only derived paths. The demo creates host
`<project-root>/.data` and carries it through provider shares and the stable Linux alias, so provider
deletion preserves that host directory. The worked-demo phase records end-to-end destroy/up/readback;
see [durable_state](durable_state.md). An external hard kill runs no teardown, and cross-process
restart convergence is owned by the [recovery and migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md).
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
- The **container frame skips the build**, because the image already carries the installed binary. The
  root catalog derives its one-layer route through `Lift.foldLeaf`; the process owner launches the hidden
  authenticated child entry and sends the exact admitted package. The receiver verifies root scope,
  installed key, payload binding, and grant before writing or dispatching the child configuration.
  Storeless execution then runs only the catalog-selected local nodes and returns observations for root
  settlement. The [authenticated handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
  owns the wire, while the [recursive lifecycle phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
  owns the live root and child process route.

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

The role admission key is a bounded domain-separated digest of the signed plan/frame/revision and measured
instance. Its durable row moves from `Reserved <role-plan-digest>` to `Consumed <role-plan-digest>`.
A lost reservation acknowledgement rehydrates the same version-bound reservation; a lost cursor-delivery
acknowledgement reports `RoleAdmissionOpenUnknown`, and `resumeRuntimeRolePlanOpen` reconstructs only that
same consumed lineage. The nominal plan, binding, placement, effect authorization, and cursor indices cannot
be coerced across identities. The initial cursor is one-use even in-process. Callback results are forced
inside the masked exception boundary; a caught asynchronous exception becomes the phase's typed failure and
the runner still reaches Drain. For an unknown acquisition, the release callback's deliberately narrow
contract is a total idempotent reprobe-and-release: only `Released` resolves the unknown; failure retains it
in the exit report. An orderly `ServeShutdown` is clean exactly when Drain has no failure or unresolved
resource, matching `roleExitReportOk`.

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

A project has one lifecycle representation. `mkStepPlan` validates the authoring graph; the generative
`ProjectPlan` retains the exact configuration, resources, dependency edges, topology, descent projectors,
operation keys, and reverse policies. Rendering, forward execution, recursive catalog construction, and
teardown consume projections of that same plan. A separate list of cleanup commands is not a second plan.

The pure reverse projection is non-authorizing. The root entry joins it to exact snapshot, lease, journal,
cursor, and command evidence. `TeardownForest` exposes closed local/descent work and preserves the opening
frame through every successor and `SubtreeSettled`. Only complete unique-root settlement yields
`DestroySettled`; Production closure additionally rechecks the live store and complete closure proof.
Unknown effects retain their recorded recovery obligation and cannot be silently treated as absent.

The reusable source contracts live in
[ProjectPlan](../../core/hostbootstrap-core/src/HostBootstrap/ProjectPlan.hs),
[Chain](../../core/hostbootstrap-core/src/HostBootstrap/Chain.hs), and
[Teardown](../../core/hostbootstrap-core/src/HostBootstrap/Teardown.hs).
The [lifecycle state model](lifecycle_state_model.md) owns their journal, recovery, migration, and closure
relationships; it links to the actual signatures rather than maintaining another illustrative API.

Production and Harness use the common interpreter with distinct exact scopes. The test engine generates
one run configuration, acquires its protected ownership, retains its Harness plan, runs assertions, and
reverses that plan. A restart assertion closes the settled generation and reopens the same run before
readback. Generated-config cleanup requires both the recorded kernel identity and matching bytes.

The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) records Production recursive
lifecycle, distinct automatic service exposures, concurrent signed roles, and Harness durable recreate
acceptance. The substrate acceptance phases separately record the accelerator/provider behavior they
exercise. Those dated records, rather than this guide, own test counts and host-specific evidence.

## Activated service composition

`service run` is the leaf-runtime join, not another project-plan interpreter. The platform supplies three
absolute coordinates: `HOSTBOOTSTRAP_SERVICE_ACTIVATION` names one immutable digest-addressed revision,
`HOSTBOOTSTRAP_ACTIVATION_KEY` names the independently installed public key, and
`HOSTBOOTSTRAP_AUTHORITY_STORE` names the protected store whose identity the activation retains. Kubernetes
also supplies `HOSTBOOTSTRAP_POD_UID` plus `HOSTBOOTSTRAP_CONTAINER_RESTART_COUNT`; a host service supplies
the mutually exclusive `HOSTBOOTSTRAP_SERVICE_INVOCATION_NONCE`.

The command hashes its own executable and the installer-owned role/config and private-bundle bytes. Signature,
revision identity, key equality, manifest equality, binary/config/secret measurements, concrete instance, and
protected-store origin must all agree before registry selection. The signed specification digest then authorizes
the one internal nominal reindex of the finalized registry. Selection uses only the activation's service identity
and narrowed role wire; the sibling full project config is neither opened nor passed to the handler.

One `serviceProgramDefinition` packages its immutable role draft, acquisition/probe/release backend, declared
type-level effect row, payload-family backend, role codec, and `RoleParams -> ServiceProgram` handler. Plan opening
consumes the exact decoded `ValidatedServiceRequest`, retaining its config, secret, specification, and service
indices through `VerifiedServicePlacement`. `authorizeServiceEffects` can therefore mint only the authorization
for that definition's row, and `interpretServiceProgramWithReady` receives only the resource handles which the
engine acquired and probed. A lost Reserved→Consumed acknowledgment reopens that same request-indexed plan; a
different request, frame, service, instance, store, effect ceiling, or specification refuses before acquisition. The handler has the rank-2
`ProgramServiceHandler payload effects fields` type: it consumes only its selected `RoleParams` and returns
`ServiceProgram payload service effects ()`. This is the sole definition path. Selection preserves the
request and program together, and neither the registry nor its selectors expose an unrestricted IO handler.

The protected-store entry ends after that admission transaction mints the sealed plan, placement, and one-use
cursor. The runtime executes the returned lifecycle action only after releasing the global store lock. During
Serve it retains only the named service/frame liveness lease required by its effects. Independent web and
accelerator roles can therefore share one authority store and run concurrently without weakening either their
transactional admissions or their distinct generation leases.

The worked demo obtains the image binary digest from the exact built image, projects the narrowed role wire from
the jointly finalized Production registry, and sends the canonical manifest through the authenticated child
relay. The root accepts signing only when the manifest names its admitted plan and an exact activation
placement declared by either a chart workload or an ordinary plan step. The two declaration families share one
frame namespace and one exact plan-digest/service/effect comparison; neither carries runtime measurements or a
signing handle. The child installs the returned grant beneath the profile's shared durable root, and the
workload receives only the immutable revision basename. Kubernetes mounts that revision read-only, mounts the
separate authority store, supplies pod UID, and reads the matching container restart count through a dedicated
pod-`get`-only service account before entering `service run`.

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
  plus the recursive `project up` interpreter, the host-management step kinds, the `ensure` kind, the execution-shape taxonomy, and the
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
