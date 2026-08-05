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

### Sprint 12.4: The step action's result [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Let what a step observes become a reconcile result rather than being discarded.

#### Deliverables

- A step's action returns a typed observation rather than `()`, so the interpreter can convert it into a
  `ReconcileResult` row for that node.
- The observation is plan-independent; the *interpreter* performs the conversion, because a
  `ManagedResult`/`ForeignResult` needs the resource handle and receipt only the prepare path can mint.
- A node that observed a conflict, a safety refusal, or an unsupported backend contributes its own structured
  row, so a report card distinguishes them rather than showing one undifferentiated failure.
- A `ManagedResult Unchanged` retains its handle and teardown receipt through the interpreter, so an idempotent
  node is still owned at teardown.

#### Validation

`StepSpec` and `ChainSpec` cover the returned observation and the interpreter's conversion for each row.

#### Remaining Work

All of it. The action signature is currently result-free, so nothing a step observes can become a row. This is
the item the test-harness phase's `Conflict`/`Unsupported` report rows and receipt-carrying results wait on, and
it depends on the step-reaches-a-gate item in the prepared-operations phase, because the managed row needs the
handle a gate mints.

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
