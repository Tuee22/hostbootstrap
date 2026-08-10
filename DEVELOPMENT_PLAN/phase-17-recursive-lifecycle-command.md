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

- `project up|down|destroy` each run behind `verifyOperatorAuthorization` →
  `withVerifiedRootInvocation`; the resulting exact root authority enters only the verb-specific
  lifecycle gate that owns the matching evidence package.
- The decoded context is descriptive input to the plan, never the thing that permits the verb.
- `project init` writes a project's initial config and is the only lifecycle verb that does not require a plan.

#### Validation

`CLISpec` covers the gate for each verb and the refusal when the operator check fails. Dated live evidence: the
three verbs ran through the gate on native linux-cpu.

#### Remaining Work

None.

### Sprint 17.2: Current-frame forward interpretation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Drive one authorized frame's exact forward ordering and derive its declared descent boundary.

#### Deliverables

- `runChainFromFrame` reads the frame context off the plan and selects only that frame's non-empty segment;
  `DerivedTopology` identifies a declared child boundary but grants no child admission.
- Each node's action receives its plan-minted execution descriptor.
- The descent declaration retains the exact child config through the announcing node, so the row that
  announces a child and the bytes an authenticated child entry consumes are the same fact.
- A node's failure stops its own subtree and is reported structurally.

#### Validation

`ChainSpec` covers current-frame order, typed descent selection, the per-node descriptor, and failure
containment. Authenticated process entry and cross-frame continuation remain open below.

#### Remaining Work

None.

### Sprint 17.3: Frame-indexed reverse projection [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Propagate the exact frame already retained by the plan-derived reverse projection through every recursive
forest state and authorization branch.

#### Deliverables

- Sprint 12.26 has already made `TeardownPlan scope planId frame verb` the exact plan-derived,
  current-frame projection and made `openTeardownForest` consume that projection alone. This sprint does
  not derive or request a second `CurrentFrame` witness.
- `TeardownForest` and every progress, authorization, cursor, and completion value propagate the
  projection's existing `frame` phantom, so the recursive state remains bound to the frame that opened it
  rather than merely accompanied by its name.
- Whether an offered node belongs to this frame is a **closed sum with a total eliminator**: a local
  cursor is the only value the local reverse runner accepts, and a foreign cursor's sole continuation is
  the descent. The forest carries every frame's levels, because one memoized descent settles the deeper
  ones; what makes the boundary hold is the index, not the forest's contents.
- A forest opened at a nested frame schedules only that frame and its descendants; an ancestor is never
  reclassified as another inward descent.
- `openTeardownForest` continues to consume only the already frame-indexed projection; no recursive caller
  may supply a frame name or duplicate descriptive witness beside it.
- A local node runs the reverse its own forward step declared, read off the local cursor rather than resolved
  beside the plan. `teardownCursorRun`, `teardownCursorPolicy`, and `teardownCursorKey` accept only that local
  cursor.
- `settledDestroyEvidence` is the only route from a completed forest to `DestroySettled`, and it matches on the
  verb index inside the module — a `down` yields nothing. A run that never visited a deeper frame's nodes has a
  forest that cannot complete, so it cannot mint the proof for nodes it never visited.

#### Validation

`TeardownSpec` covers root, VM, and container openings over a real multi-frame fixture: local work is the only
work exposed to the local runner, the foreign branch names only a descent, and no nested opening exposes an
ancestor. `CompileFailSpec` pins that a local cursor indexed by one frame is not accepted by another.

#### Remaining Work

Frame-index propagation beyond `TeardownPlan`, the local/descent sum, focused scheduling, and compile-fail
proof.

### Sprint 17.4: Operator and authenticated descent lifecycle entries [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Give operator and nested lifecycle invocations different, non-interchangeable admission types.

#### Deliverables

- A lifecycle-specific validated context binds project/binary identity, topology, orchestration placement, and
  runtime witnesses without selecting a command class from descriptive config.
- Operator `up`, `down`, and `destroy` entries are constructible only at the topology root through the
  verified operator/root authority chain and the root `CurrentFrame`.
- A forward descent entry is constructible only from the exact verified config handoff, child-plan authority,
  verb, plan digest, parent/child edge, and current child frame supplied by the
  [authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md). It yields the child's
  local plan-bound command admission; a config payload or process invocation alone grants nothing.
- A descent teardown entry is constructible only from the typed verb and exact
  `VerifiedRecoveryHandoff` produced by the
  [authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md).
- Each descent producer rechecks its plan digest, parent/child edge, verb, lifecycle phase, wire digest, and
  current child frame before yielding its opaque entry.
- A nested `project up|down|destroy` reached from `argv` alone refuses before effects; no flag, environment
  variable, config class, or caller-chosen source constant selects the nested entry.
- The live descent entry owns construction and lifetime of its duplex `HandoffChannel`; ordinary project code
  cannot retain a raw channel beside the verified `ReceivedEdge` and bypass the repository-sealed requester
  path. This strengthens the § HH in-repository boundary without pretending to cryptographically constrain an
  external process; exact root plan admission remains the final authorization.
- The teardown verb index is the same closed `ProjectVerb` index the command authority uses, so an authorized
  `down` cannot drive the destroy projection.

#### Validation

Command-entry tests cover operator and authenticated forward/reverse descent success plus every wrong-binding
refusal. `CompileFailSpec` pins that the descent-entry constructors are hidden and no producer exists without
the matching verified handoff evidence.

#### Remaining Work

The operator/descent entry families, including authenticated forward child admission, transport ownership
that removes the retained raw-channel bypass from ordinary project code, and their proof fixtures.

### Sprint 17.5: Authenticated recursive interpretation and unwind [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/engineering/composition_patterns.md`

#### Objective

Drive forward and reverse traversal through authenticated child entries and settle every reachable frame.

#### Deliverables

- `project up` reaches a declared boundary only by opening the plan-bound handoff edge, running the duplex
  exchange, and invoking the child's exact authenticated forward entry; the child then interprets its own
  current-frame segment and repeats the same protocol for any declared descendant.
- `project down` and `project destroy` descend through the plan-declared edge, invoke the same typed verb in
  the child, and settle that child's nodes before the parent node.
- The recovery protocol owns the child's `stdout`; diagnostics and structured teardown rows use `stderr` while
  the duplex exchange is active.
- `driveTeardownForest` owns ordering, outstanding work, and terminal failure; a verb supplies only one local
  effect, one authenticated descent, and one report row.
- The destroy-only pre-descent reachability step succeeds only through reaching and admitting the exact child
  frame.
- A failed `project up` invokes the same authenticated destroy projection, so there is one release route.
- Every node reports released, retained, refused, or failed, and an unresolved deeper frame prevents settled
  destroy evidence.

#### Validation

`TeardownSpec` drives the real command entry across a process boundary, including wrong/replayed recovery
wires and failure containment. The phase gate then runs live `project up`, `project down`, and
`project destroy` on linux-cpu and records the dated result.

#### Remaining Work

Authenticated forward and reverse duplex call-site adoption, channel ownership that keeps raw transport out
of ordinary project code, and the live half of the phase gate.

Consuming `DestroySettled` as `ProjectClosureEvidence SettledDestroyClose` needs a bound run lease and the
all-sessions-closed proof. The [recovery phase](phase-18-recovery-and-migration.md) owns that later boundary.

## Remaining Work

Propagate the reverse projection's existing frame index through the teardown forest, implement the closed
local/descent sum, add the operator and authenticated child entry families for all three lifecycle verbs,
make those entries own their raw duplex channels, and adopt them in the recursive forward and reverse call
sites. The complete static gate and
live linux-cpu `project up`, `project down`, and `project destroy` gate then validate the phase.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` — recursive interpretation and child-first unwind.
- `documents/architecture/hostbootstrap_core_library.md` — the surfaced lifecycle verbs.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` — the recursive interpreter as the canonical pattern.
- `documents/operations/demo_runbook.md` — the operator-facing verb sequence.

**Cross-references to add:**
- `development_plan_standards.md` § Y names this phase as the owner of the lifecycle command.
