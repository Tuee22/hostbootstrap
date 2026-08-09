# Phase 12 — The step algebra and the single project plan

**Status**: Done
**Depends on**: Phase 11 (prepared operations and preconditions)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Express a project's whole deployment as **one** validated plan value whose forward ordering,
> frame descent, and reverse effects are all nodes of that same value.

## Phase Objective

A deployment has three views: the order things happen in, the frames they happen inside, and what releases
them. Held as three separate structures they disagree silently — teardown releases something the forward pass
never acquired, or misses something it did. This phase makes all three **projections of one plan**, so the
disagreement is unrepresentable.

## Sprints

### Sprint 12.1: The step algebra [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/test/StepSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

A closed core step vocabulary plus a disjoint project namespace.

#### Deliverables

- `CoreStepId` is closed; `ProjectStepId` is validated and lives in a disjoint namespace, so core and project
  identities cannot collide even when they render alike.
- A `StepFrame` carries a semantic id and a presentation label; validation rejects two labels for one id.
- `mkStepPlan` validates a step list into an opaque `StepPlan`: it reads the declared frame boundaries and
  refuses a plan with a missing or duplicated descent.
- A step declares its own frame boundary with `descendsVia`; exactly one per frame that has a successor, and
  none from the innermost. There is no separate topology table to disagree with.
- An acquiring step declares its reversing effect with `reversedBy`; a step that preserves declares
  `PreserveOnReverse` and is in neither teardown projection.
- Step fragments are rank-2 in the canonical root, so the whole plan is root-bound.

#### Validation

`StepSpec` covers identity disjointness, frame validation, the descent rules, and the preserve policy.

#### Remaining Work

None.

### Sprint 12.2: The validated lifecycle plan [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`, `core/hostbootstrap-core/test/LiftSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

One opaque plan, indexed by scope and a generative plan identity.

#### Deliverables

- `withLifecyclePlan` consumes a scope-correct codec and a validated `StepPlan` and yields
  `LifecyclePlan scope planId` in a rank-2 continuation, so a plan identity cannot escape its interpretation.
- `lifecyclePlanSteps` and `lifecyclePlanFrames` read the validated steps out of the plan itself, so a consumer
  cannot supply a different step list beside it.
- `lifecyclePlanDigest` and `lifecyclePlanSnapshot` derive the plan's identity from its canonical bytes.
- `HostBootstrap.Lift` is the self-reference lift: a frame's context is derived from its parent's, and the
  `context-init` row that announces a child config is the node that carries it.
- `Reconcile.stepExecutionFor` is the sole producer of a step's execution descriptor.

#### Validation

`ChainSpec` and `LiftSpec` cover plan construction, the digest derivation, the descent, and that the announcing
row carries the child config.

#### Remaining Work

None.

### Sprint 12.3: The verb-indexed reverse projection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Both teardown verbs are projections of the one plan.

#### Deliverables

- `teardownPlan` takes only a `LifecyclePlan` and a verb and reads the steps out of the plan, so the forward
  traversal and the reverse teardown cannot name different resources.
- `TeardownPlan scope planId verb` is verb-indexed: a `down` projection, live forest, or completed proof cannot
  be substituted for a `destroy` one.
- The verbs differ in exactly one place: a provider frame is stopped by `down` and deleted by `destroy`, while
  an ephemeral cluster is deleted by both, because it has no reliable stop contract — see
  [rationale.md](rationale.md).
- A `PreserveOnReverse` step enters neither projection, which is how a durable host root stays inside the one
  plan with an explicit policy rather than being excluded by a call-site special case.
- `openTeardownForest` is the sole initial producer and enforces child-first recursion; for `destroy` a provider
  node first offers a pre-descent reachability step, whose success is what exposes the children.
- Failure is constructive: every attempt returns a successor forest, a failed node blocks only its own parent,
  and scheduling is two passes so a failing node cannot starve its siblings.
- Foreign and refused observations settle their node without touching the object and are recorded separately
  from failures.
- `verifyDestroySettled` accepts only a completed `Destroy` forest and refuses one that settled fewer nodes than
  the projection names.

#### Validation

`TeardownSpec` covers identical identities across verbs, the per-verb effects, the child-first order on a
three-frame shape, the pre-descent step, constructive failure, and the truncated-traversal refusal.

#### Remaining Work

None.

### Sprint 12.4: The step action's result [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Let what a step observes become a reconcile result rather than being discarded.

#### Deliverables

- A step's action returns a typed `StepObservation` rather than `()`, so the interpreter can convert it into a
  `ReconcileResult` row for that node.
- The observation is plan-independent — it carries no handle, receipt, or plan index — so an action can
  describe what it saw without claiming ownership it did not acquire. The *interpreter* performs the
  conversion, because a `ManagedResult`/`ForeignResult` needs the resource handle and receipt only the prepare
  path can mint.
- A node that observed a conflict, a safety refusal, or an unsupported backend contributes its own structured
  row naming both the node and the kind of outcome, so a report card distinguishes them rather than showing one
  undifferentiated failure. All three are terminal for the chain: the node did not reach its target state, so a
  later node that depends on it would act on a precondition that does not hold.
- The interpreter runs every node as the § EE transaction: the durable unknown phase is recorded **inside** an
  exclusive entry before the effect, the effect itself runs **outside** any entry — a provider call must not
  hold the store's lock for its duration — and the node is settled inside a fresh entry afterwards. The gate
  the interpreter opens is the node's **own** operation's, reached through `withStepPreparedGate` off the
  node's plan-minted descriptor, so a node cannot prepare a sibling's.
- A step that *throws* a safety refusal settles exactly as one that *returns* it: both are definite, so both
  settle terminally. Any other exception leaves the record at its unknown phase, because whether the effect
  landed is precisely what nobody can say — settling that would be a claim the run cannot make.
- The session identity is per **invocation**, derived from the freshly allocated broker generation, so a
  second `project up` cannot collide with a predecessor's session record.

#### Validation

`StepSpec` covers the observation vocabulary: which outcomes are successes, and that each renders a distinct
row. `ChainSpec` covers the interpreter's conversion — a node that reached its target state lets the chain
continue, and each non-success outcome stops it, names its own node, names its own kind, and leaves the later
nodes unrun — and its **durable** transaction: a node's action reads its own record mid-effect and finds the
unknown phase already published, which simultaneously proves the ordering and that the exclusive entry is free
while the effect runs; a node that reached its target state settles at `Committed`; one that did not settles
terminally rather than as an unclassifiable unknown.

#### Remaining Work

None. The interpreter opens each node's gate as part of its transaction and settles against it. Minting a
managed handle through a gate is a **resource adapter's** act, not the generic interpreter's — the interpreter
cannot know a node's resource identity, which is why the observation is plan-independent. What an adapter needs
to reach a gate at all is the next sprint's.

### Sprint 12.5: A node's projected operations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Let a node reach the gate for an operation projected from it, not only for itself.

#### Deliverables

- A resource that *relates* others has an operation key derived from the keys it relates — the guest alias
  is `<provider>/<share>/guest-alias` — so it is nobody's own key. `projectsOperation` is where a step
  claims one, in the same validated plan the forward traversal, the descent, and the reverse projection are
  taken from.
- `mkStepPlan` admits a projected key of exactly the shape
  `<zero or more of the declaring step's dependency keys, in plan order>/<its own key>/<suffix>`, with a
  non-empty separator-free suffix. The declaring node is therefore the **last** resource the key names,
  which is the only node that can perform the relation: every other resource the key names is already
  behind it in the plan. The guest alias is claimed by the durable-share node, whose prefix carries the
  provider.
- A projected key is claimed once across the plan and may not collide with a node's own operation key, so
  two nodes cannot register, gate, and settle one durable operation record.
- The interpreter registers each node's projections with the node, opens a gate for each in the same
  exclusive entry that publishes the node's own unknown phase, and settles the ones the action took at the
  phase the node itself settles at.
- A step's action reaches its own node's gate (`stepExecutionPreparedGate`) and takes a projection's gate by
  key (`stepExecutionTakeProjectedGate`), once each. A key the plan did not place under this node yields
  `Nothing`, so an adapter reaches exactly what the node declared and no sibling's.
- A node that declares a projection and does not take its gate leaves that operation unsettled, so
  `closeOperationSession` refuses and the chain fails closed. Declaring a relation the node does not perform
  is a plan error, not a silent success.
- `mkRecordName` (the protected-store phase) already encodes a `/`-separated identity path injectively, so a
  relation's key names a durable record without a sanitizer.

#### Validation

`StepSpec` covers the declaration, the shape rule in both directions, and both uniqueness rules. `ChainSpec`
drives the real interpreter: an action takes its projection's gate and is refused a sibling's, its own key's,
and a second take; the descriptor names exactly the validated projections; a projection registers and settles
`Committed` with its node and `StepObservedTerminal` when the node does not reach its target state; and a
declared projection whose gate is never taken refuses the close naming that operation.

#### Remaining Work

None.

### Sprint 12.6: Carried managed handles [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Let the node that acquires a resource hand it to the node that depends on it.

#### Deliverables

- A prepared call's dependency snapshot consumes the dependency's **managed** handle, and a generative handle
  is never serialized (§ EE): its identity index is a skolem of the bracket that minted it. It therefore has
  to travel in process, inside one interpretation.
- The interpreter opens one `ResourceCarrier scope planId` before its first node and threads it through every
  node's descriptor, so the carrier's plan indices are the interpretation's own.
- `carryManagedResource` takes a `Managed` handle — which only `completeReconcile` and
  `completePreparedUnchanged` produce — so an unowned or foreign resource cannot be carried. Carrying a key
  twice keeps the newer identity, which is the one a re-run acquired.
- `withCarriedManagedResource` reads one back under fresh generative indices in a rank-2 continuation, and
  only for a key in **this node's** exact ordered plan prefix. A dependency nobody carried is a typed
  reprobe failure, never an empty success.

#### Validation

`ChainSpec` drives a real interpretation in which one node acquires its cluster through the production
prepared path against its own gate and carries it, and the node after it adopts the same key, generation, and
observation version. A node reaching outside its prefix is a conflict; an uncarried dependency is a failure.

#### Remaining Work

None.

### Sprint 12.7: The node's plan view [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Let a step action name the planned resources its own node may act on, without handing it the plan.

#### Deliverables

- A step action receives the descriptor the plan minted for its node, never the `LifecyclePlan`. A planned
  resource is a plan digest, an operation key, and a frame, so the descriptor carries each dependency's frame
  alongside its key and the node can name what the plan already placed.
- `withNodeResourceOfKind` resolves the node's own resource or one member of its ordered prefix, under the
  same closed `PlannedResourceKind` relation the plan-level route uses. A key outside that set is refused
  even when the plan contains it.
- `withNodeObservedResource` compares the planned resource's plan digest against the descriptor's, which the
  plan-level route cannot: an action holds only descriptors and could otherwise pair another plan's resource
  with this node's gate.
- `plannedNodeOperation` plans an operation on the node's **own** resource, reading the same ordered
  edge set the plan-level route reads and narrowing it to its resource-bearing members.
- `withNodeGuestAliasProjection` derives the guest alias from the node's own declared projection, requiring
  the provider to precede the durable share in the node's plan order.

#### Validation

`ChainSpec` reaches `withNodeResourceOfKind`, `withNodeObservedResource`, and `plannedNodeOperation` from
inside a real step action to acquire a managed cluster; `ProviderAliasSpec` continues to cover the
plan-level projection, and the [host-providers phase](phase-15-host-providers-and-the-lift.md) covers the
node-level alias route at its production call site.

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 988/988 on
2026-08-05 (aarch64-osx, GHC 9.12.4), and the demo suite passed 112/112.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` — the one-plan doctrine and the three projections.
- `documents/architecture/durable_state.md` — the preserve policy for durable roots.
- `documents/architecture/run_models.md` — execution shape is the plan, not a separate selector.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` — authoring step fragments.
- `documents/engineering/authoring_project_binaries.md` — a consumer authors fragments finalized into a plan.
- `documents/engineering/dhall_topology.md` — topology frames as declared descents.

**Cross-references to add:**
- `development_plan_standards.md` § T, § U, and § W name this phase as the owner of the plan contract.
