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
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Make each verb clean the frames the current binary can reach, deepest first.

#### Deliverables

- `project down` and `project destroy` descend into the next frame — invoking the **same verb** there through
  the descent the plan itself declares — and settle that frame's nodes from that invocation, so a deeper frame
  is released by the binary that can see it rather than released implicitly with its parent. The child runs the
  same loop over its own segment and recurses further itself.
- The teardown **forest** is what the verbs drive, so its child-first ordering and its destroy-only pre-descent
  reachability step govern actual effects. The reachability step is satisfied by reaching the child frame:
  invoking the child binary is what demonstrates the stopped provider is reachable again.
- `driveTeardownForest` owns the loop, because the forest is what knows the ordering, the outstanding set, and
  that a failed node is terminal for the run. A verb supplies one node's effect and one node's row and nothing
  else; a node the forest re-offers after a failure ends the run with every outstanding node named.
- A node runs the reverse its own forward step declared, read off the cursor rather than resolved beside the
  plan. `teardownCursorRun`, `teardownCursorPolicy`, and `teardownCursorKey` are what make the forest
  drivable without a second lookup that could disagree with the projection.
- The projection is **frame-indexed**. `TeardownPlan`, `TeardownForest`, and `TeardownCursor` each carry a
  `frame` phantom, and the sole forest producer consumes a `CurrentFrame scope planId frame` witness
  derived from the `LifecyclePlan` together with the validated binary context — so a forest is bound to
  the frame that opened it rather than merely accompanied by its name.
- Whether an offered node belongs to this frame is a **closed sum with a total eliminator**: a local
  cursor is the only value the local reverse runner accepts, and a foreign cursor's sole continuation is
  the descent. The forest carries every frame's levels, because one memoized descent settles the deeper
  ones; what makes the boundary hold is the index, not the forest's contents.
- The two entries are distinct types (§ X). An **operator-initiated** `down`/`destroy` validates at the
  topology root and nowhere else. A **descent-initiated** one runs in a nested frame and is admitted only
  by verifying the recovery wire its parent minted from this forest's own authorization point, so it is
  unreachable from `argv`, an environment variable, or a flag. A lifecycle verb names no command class as
  a source constant chosen per call site.
- A failed `up` unwinds through the same call, so there is one release path rather than a cleanup beside it.
- Each node's outcome becomes a structured row: released, retained, refused, or failed.
- `settledDestroyEvidence` is the only route from a completed forest to `DestroySettled`, and it matches on the
  verb index inside the module — a `down` yields nothing. A run that never visited a deeper frame's nodes has a
  forest that cannot complete, so it cannot mint the proof for nodes it never visited.

#### Validation

`TeardownSpec` covers the projection and the forest in isolation, and the production driver directly: the order
every node is offered in (pre-descent, then deepest frame, then outwards), one row per node, a failing node
ending the run with its blocked chain named and no spin, a foreign settlement not blocking completion, and a
`down` run being unable to mint settled-destroy evidence while a `destroy` run mints it for the plan's own
digest.

#### Remaining Work

The frame index, the two entries, and the live half of the phase gate.

The forest, its ordering, and the per-node rows are built. What the descent still needs is the typed
boundary: the `frame` phantom and its `CurrentFrame` witness, the local/foreign cursor sum, and the
descent entry that admits a nested verb by verifying the recovery wire the
[authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md) owns. Until those
land the descent has no admission a nested frame accepts, so `project destroy` settles the frames one
binary can reach and reports the rest outstanding.

The § HH proof obligations are part of this sprint: a compile-fail fixture pinning that a cursor indexed
by one frame is not accepted in another, and a second pinning that the descent entry has no constructor
without a verified wire. `TeardownSpec` gains a fixture whose levels carry frames with different legal
command classes, because a projection driven over synthetic single-frame levels cannot exercise a frame
boundary at all.

Dated evidence: `cabal test all --ghc-options=-Werror` from `core/` passes on 2026-08-08 (aarch64-osx,
GHC 9.12.4). The declared live `project up`/`down`/`destroy` lane is owed.

Consuming the `DestroySettled` proof as `ProjectClosureEvidence SettledDestroyClose` needs a bound run lease
and the all-sessions-closed proof, which the lifecycle verbs do not open — that is the
[recovery phase](phase-18-recovery-and-migration.md)'s, not this one's.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` — recursive interpretation and child-first unwind.
- `documents/architecture/hostbootstrap_core_library.md` — the surfaced lifecycle verbs.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` — the recursive interpreter as the canonical pattern.
- `documents/operations/demo_runbook.md` — the operator-facing verb sequence.

**Cross-references to add:**
- `development_plan_standards.md` § Y names this phase as the owner of the lifecycle command.
