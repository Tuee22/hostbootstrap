# Phase 19 — Test harness and exclusive run ownership

**Status**: Active
**Depends on**: Phase 18 (recovery and migration)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus a live `test run all` on linux-cpu

> **Purpose**: Make a test run an exclusively owned transaction whose failures are isolated per variant and
> whose cleanup cannot delete foreign or concurrently replaced state.

## Phase Objective

A test run mutates real infrastructure, so it needs everything the lower phases built: an exclusive mode, a
recoverable lease, clause-holding ownership of the objects it generates, and a sweep that resolves whatever a
killed predecessor left. What this phase adds is the engine on top: per-variant isolation, a structured report
card, and a cleanup driven by receipts rather than by paths.

The harness has no route to production. A project's test component receives only the harness-indexed planning
function, and cluster name, data root, and ports all derive from the run identity.

## Sprints

### Sprint 19.1: Exclusive run ownership [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

One bracket that owns everything a run touches, in one order.

#### Deliverables

- In order, a run takes the project-wide liveness lock and holds it for the whole run; sweeps every abandoned
  run; takes the Harness mode and its lease in one compare-and-swap with the safety recheck inside it; takes
  ownership of its own `.test_data/<runId>` generation; and takes ownership of its generated sibling config.
- On exit it settles **both** owned objects and only then closes the lease and releases the mode, because the
  sweep enumerates incomplete *leases* and a record outliving its own lease is unreachable forever — see
  [rationale.md](rationale.md).
- The shared data-root parent is scaffolding: created if missing, never owned, never removed.
- A conflict on either object is reported and the object left intact; the run's report card carries the row.
- The sole config existence refusal derives its subject from installed project identity and runs *after* the
  sweep, so an interrupted run's own config is reclaimed before anything can refuse on it, while an operator's
  config still refuses the run and survives it untouched.

#### Validation

`HarnessSpec` covers the acquisition order, both settlements, the conflict reports, the post-sweep refusal
ordering, a hard kill holding each owned object, and a racing-harness probe converging on one acquisition.

#### Remaining Work

None.

### Sprint 19.2: The engine and per-variant isolation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Run the matrix so one variant's failure does not hide another's result.

#### Deliverables

- Pure stable variant drafts are validated first; then a fresh generative run and lease open for each distinct
  config variant. Cases sharing a variant share its stack, and no later variant starts while the prior lease is
  unresolved.
- Each chosen case carries exactly one engine-classified outcome, so a bring-up failure and an assertion failure
  are distinct rows rather than one aggregate.
- Cleanup failures are their own rows: a data-root cleanup failure, a generated-config cleanup failure, and a
  mode-close failure are separately named.
- The report card renders every case for every variant, including a suite with no cases.
- A project's test component receives only the harness-indexed planning function; there is no route to the
  production planner, proved by a compile-fail fixture.

#### Validation

`HarnessSpec` covers per-case classification, each cleanup-failure row, the empty suite, and the variant
sequencing. `CompileFailSpec` proves the production planner is unreachable.

#### Remaining Work

None.

### Sprint 19.3: Reconciler-produced report rows [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Let the report card carry what the reconcilers actually observed.

#### Deliverables

- An acquisition `Conflict`, a `SafetyRefusal`, and an `Unsupported` outcome are distinct structured rows, so a
  skipped resource reads as skipped rather than failed.
- A `ManagedResult Unchanged` row retains its managed handle and teardown receipt; a `ForeignResult` row exposes
  only an unmanaged handle that cannot type-check at teardown.
- Independent variants continue when it is safe to do so, and a teardown failure turns its own variant red
  without aborting the others.

#### Validation

`HarnessSpec` covers each row's rendering and that a foreign row's handle is rejected at teardown.

#### Remaining Work

The row *vocabulary* exists in the result algebra and a step's action now returns an observation the chain
interpreter converts into that node's row, but no **harness** call site produces those rows: the engine still
reports a variant's outcome without the reconcile rows its nodes observed. A `ManagedResult`/`ForeignResult`
row additionally needs the handle and receipt only a prepared call mints, which is the carried-handle item in
the step-algebra phase; the structured per-node teardown rows are the recursive-lifecycle-command phase's.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/harness_workflow.md` — the ownership bracket, the sweep, and the engine.
- `documents/architecture/run_models.md` — execution shape is the lifecycle plan.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the report card, per-variant isolation, and what the static suites cannot
  cover.

**Cross-references to add:**
- `development_plan_standards.md` § W and § Z name this phase as the owner of the harness engine.
