# Phase 17 — The recursive lifecycle command

**Status**: Active
**Depends on**: Phase 13 (authenticated handoff and child admission), Phase 16 (cluster lifecycle, budgets,
and cordoning)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus live
`project up`, `project down`, and `project destroy` on linux-cpu

> **Purpose**: Interpret the one project plan recursively across every frame, and unwind it child-first when a
> verb or a failure requires it.

## Phase Objective

This is where the plan becomes effects. `project up` descends frame by frame, handing each child its config and
its authority, and each node's effect passes the prepare gate. `project down` and `project destroy` are the same
plan's reverse projections driven to settlement, and a failed `up` unwinds through the same machinery rather
than through a separate cleanup path.

Authorization is independent of the configuration being interpreted: the three verbs run behind the operator →
root → command chain, not behind a context class the config asserts about itself.

## Sprints

### Sprint 17.1: The independent root gate on the three verbs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Authorize a lifecycle verb from a verified invocation, not from the config.

#### Deliverables

- `project up|down|destroy` each run behind `verifyOperatorAuthorization` → `withVerifiedRootInvocation` →
  `authorizeProjectCommand`.
- The decoded context is descriptive input to the plan, never the thing that permits the verb.
- `project init` writes a project's initial config and is the only lifecycle verb that does not require a plan.

#### Validation

`CLISpec` covers the gate for each verb and the refusal when the operator check fails. Dated live evidence: the
three verbs ran through the gate on native linux-cpu.

#### Remaining Work

None.

### Sprint 17.2: Recursive forward interpretation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Drive the plan's forward ordering across frames.

#### Deliverables

- `runChainFromFrame` reads the frame context off the plan, so the interpreter descends where the plan says and
  nowhere else.
- Each node's action receives its plan-minted execution descriptor.
- Descent at a frame boundary hands the child its config through the announcing node, so the row that announces
  a child and the bytes the child reads are the same fact.
- A node's failure stops its own subtree and is reported structurally.

#### Validation

`ChainSpec` covers the descent order, the per-node descriptor, and the failure containment.

#### Remaining Work

None.

### Sprint 17.3: Recursive child-first unwind [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Make each verb clean the frames the current binary can reach, deepest first.

#### Deliverables

- `project destroy` at the root descends into each child frame and runs that frame's own reverse nodes before
  running its own, so a deeper frame is released by the binary that can see it rather than released implicitly
  with its parent.
- The teardown forest is driven from the real plan at the real call site, so its child-first ordering and its
  destroy-only pre-descent step govern actual effects.
- A failed `up` unwinds through the same projection, so there is one release path rather than a cleanup beside it.
- Each node's outcome becomes a structured row: released, preserved, foreign-retained, refused, or failed.
- Only a completed forest whose every projected node settled can yield settled-destroy evidence, so a one-frame
  run cannot mint it for nodes it never visited.

#### Validation

`TeardownSpec` covers the projection and the forest in isolation; the call-site behaviour is confirmed by live
`project destroy` on linux-cpu printing exactly the plan's own reverse nodes deepest-frame-first and leaving
nothing behind.

#### Remaining Work

All of it. The projection, the forest, and the settlement proof exist and are gated, but they have **no
production call site**: `project destroy` does not yet descend into child frames before running its own reverse
steps. Until it does, the deeper frames are released with their parent, and the forest's guarantees are not the
ones the live verb provides. This item also carries the structured per-node rows the test-harness phase's report
card consumes, and it depends on the step-result item in the step-algebra phase.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` — recursive interpretation and child-first unwind.
- `documents/architecture/hostbootstrap_core_library.md` — the surfaced lifecycle verbs.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` — the recursive interpreter as the canonical pattern.
- `documents/operations/demo_runbook.md` — the operator-facing verb sequence.

**Cross-references to add:**
- `development_plan_standards.md` § Y names this phase as the owner of the lifecycle command.
