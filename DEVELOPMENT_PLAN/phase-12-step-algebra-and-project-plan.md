# Phase 12 — The step algebra and the single project plan

**Status**: Active
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
terminally rather than as an unclassifiable unknown. `cabal test all --ghc-options=-Werror` from `core/`
passed 952/952 on 2026-08-05 (aarch64-osx, GHC 9.12.4), twice in succession against a persisting store, and
the demo suite passed 112/112.

#### Remaining Work

None. The interpreter opens each node's gate as part of its transaction and settles against it. Minting a
managed handle through a gate is a **resource adapter's** act, not the generic interpreter's — the interpreter
cannot know a node's resource identity, which is why the observation is plan-independent. What an adapter needs
to reach a gate at all is the next sprint's.

### Sprint 12.5: A node's projected operations and carried handles [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Let a node's own adapter reach the gate and the dependency it needs, so a resource adapter has a call site.

#### Deliverables

- A node reaches a gate for an operation **projected from** its own node, not only for the node itself. A
  relating resource's operation key is a projection of the keys it relates — the guest alias is
  `<provider>/<share>/guest-alias` — so it is not any node's own key and no node can currently prepare it. A
  step declares its projections in the plan, `mkStepPlan` requires each to be prefixed by the declaring node's
  own operation key, and the interpreter registers and settles them with the node.
- A step's action receives the gates its node opened, so an adapter reaches exactly the operations its node
  declared and no sibling's.
- Managed handles are carried in-process from the node that mints one to the node that depends on it, because
  a generative handle is never serialized (§ EE) and a prepared call's dependency snapshot consumes the
  dependency's *managed* handle.
- A node that declares a projection and does not settle it leaves that operation unsettled, so the session
  cannot close — the same rule the node's own operation already obeys.

#### Validation

`StepSpec` covers the declaration and the prefix rule; `ChainSpec` covers registration, the gates an action
receives, settlement of a node's projections with the node, and the refused close when one is left unsettled.

#### Remaining Work

All of it. Without it the guest-alias backend the
[host-providers phase](phase-15-host-providers-and-the-lift.md) built has no reachable call site, and the
[worked-demo phase](phase-24-worked-demo.md)'s alias adoption cannot be written.

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
