# Phase 19 — Test harness and exclusive run ownership

**Status**: Active
**Depends on**: Phase 18 (recovery and migration)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus on linux-cpu
`cabal test hostbootstrap-core:test:hostbootstrap-core-test --ghc-options=-Werror --test-options='--pattern recovery-interruption'`
from `core/` and `hostbootstrap run -- test run all`

> **Purpose**: Make a test run an exclusively owned transaction whose failures are isolated per variant and
> whose cleanup cannot delete foreign or concurrently replaced state.

## Phase Objective

A test run mutates real infrastructure, so it needs everything the lower phases built: an exclusive mode, a
recoverable lease, clause-holding ownership of the objects it generates, and a sweep that resolves whatever a
killed predecessor left. What this phase adds is the engine on top: per-variant isolation, a structured report
card, and a cleanup driven by receipts rather than by paths.

The harness has no route to Production. The command constructs and retains one exact Harness `ProjectPlan`
for each admitted variant, then gives the engine an opaque lifecycle over that plan. A project's `TestSuite`
owns only the safety probe, assertion-environment opener, typed case matrix, per-case assertion, and
post-reverse absence assertion; it receives no lifecycle callback or Production planning path. The exact plan
is retained through lifecycle interpretation, while the demo's cluster profile, durable root, and port terms
still enter through its independently derived run profile. Making those terms exact plan projections belongs
to the [worked-demo phase](phase-24-worked-demo.md).

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
- The engine consumes one opaque lifecycle supplied by the command and orders forward, assertions, reverse,
  and post-reverse verification without constructing or reopening a project plan.
- A project's `TestSuite` contains only the safety probe, assertion-environment opener, typed cases, case
  assertion, and post-reverse absence assertion. It receives neither lifecycle actions nor a Production plan.

#### Validation

`HarnessSpec` covers per-case classification, each cleanup-failure row, the empty suite, variant sequencing,
and engine ordering around an opaque lifecycle. The public-signature/source guard proves that `TestSuite`
cannot invoke project lifecycle operations or obtain a Production plan.

#### Remaining Work

None.

### Sprint 19.3: Exact Harness project-plan command adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/internal/harness-lifecycle/HostBootstrap/Harness/Lifecycle/Internal.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/run_models.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Retain one exact Harness project plan through generated-config ownership and drive the common lifecycle
interpreter through its closed command-owned entry.

#### Deliverables

- The Harness scope-finalized spec, lifecycle profile, and validated Harness config produce
  `ProjectPlan (Harness projectId runId) ...`.
- The generated `runId` remains in every draft, frame, snapshot, lease, journal, cursor, authority, and
  interpreted node index.
- The generated-config bracket retains that exact plan while the hidden fixed root-Up entry and exact reverse interpreter run.
- `TestSuite` owns the case matrix and assertions, while project lifecycle resides in the plan and command
  interpreter.
- Harness dispatch uses the common `forward`, `topology`, snapshot, resource, and Chain foundations through
  the Sprint 17.8 hidden root-Up entry; only that entry derives raw execute evidence.
- Test case selection remains outside project-plan construction.
- Production evidence cannot enter the Harness path.

#### Validation

`HarnessSpec`, `CLISpec`, and compile-fail fixtures cover exact run identity, direct shared interpretation,
generated-config lifetime, and Production/Harness separation. A source guard rejects lifecycle-owned
`project up` or `project destroy` self-invocation from `TestSuite`.

Dated host-static evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), the focused `HarnessSpec`, `CLISpec`,
`ChainSpec`, and `ProviderAliasSpec` groups passed 41/41, 47/47, 39/39, and 16/16 respectively; all 234
public compile-fail boundaries passed; the changed demo consumer's `hostbootstrap-demo-test` suite passed
123/123; and `cabal test all --ghc-options=-Werror` from `core/` passed 1421/1421 cases in 67.44 seconds,
including 2/2 governed-documentation checks. This is the static half of this phase's gate, not its still-owed
live linux-cpu evidence.

#### Remaining Work

None.

### Sprint 19.4: Reconciler-produced report rows [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Let the report card carry what the reconcilers actually observed.

#### Deliverables

- An acquisition conflict, a safety refusal, and an unsupported backend are distinct structured rows —
  `CONFLICT`, `REFUSED`, `SKIPPED` — so a lane the substrate cannot run reads as skipped rather than broken,
  and state an operator must resolve reads as a conflict rather than a break.
- `classifyLifecycleReason` is what produces them, and it reads the cause the interpreted chain already
  reported. A cause naming none of the three stays an ordinary `BROKEN` row rather than being guessed into one.
- The three markers live with the shared `HostBootstrap.Step` observation vocabulary. Harness imports and
  reexports those exact values, and `observationDetail` renders with them, so the row the chain interpreter
  printed and the row the report card classifies cannot drift apart.
- None of the new rows is a pass: a skipped lane did not do what was asked, and `caseResultPassed` stays total
  so a later outcome cannot be silently counted as success.
- A `ManagedResult` retains its managed handle and teardown receipt while a `ForeignResult` exposes only an
  unmanaged handle, and the guest-alias release accepts only the managed one — that is the result algebra's,
  and `ForeignGuestAliasRelease.hs` pins that a foreign handle does not type-check at teardown.
- Independent variants continue when it is safe to do so, and a teardown failure turns its own variant red
  without aborting the others.

#### Validation

`HarnessSpec` covers each row's label and reason on the rendered card, that every non-passing outcome is
counted as a failure, that each of the three causes classifies to its own row while an unrelated cause does
not, and that `observationDetail`'s own rendering of each observation classifies back to the matching row.
`CompileFailSpec`'s `ForeignGuestAliasRelease.hs` pins the foreign-handle teardown refusal.

#### Remaining Work

None.

### Sprint 19.5: Harness root-scope capsule production [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/binary_context_config.md`

#### Objective

Supply the exact generative Harness run evidence to the authenticated root-scope capsule without making the
child reconstruct a `runId` or authority from text.

#### Deliverables

- The one call-site adoption combines the live `HarnessAuthority projectId runId` with the installed project
  identity to construct the matching `HandoffScope (Harness projectId runId)`, then passes that scope and its
  live typed `RootBroker` to the generic capsule producer.
- Production and Harness capsule production remain closed branches; a Production identity cannot substitute
  for generative Harness run evidence.
- The capsule's exact seven frames carry only codec domain/version, installed project, closed Harness kind,
  canonical run text, installed-key digest, and signature; it does not bind store, broker generation, verb,
  Offer, edge, payload, or plan coordinates and never serializes `HarnessAuthority` or a signing key.
- A child obtains its existential Harness scope only through the lower authenticated scope-first receiver;
  verified run text introduces a fresh `runId` but never reconstructs `HarnessAuthority`, while `argv`, config
  text, and envelope-supplied keys introduce no phantom.
- The sprint changes at most two production modules, adds no named type, adopts one call site, targets at most
  300 production lines, and splits before exceeding 400.

#### Validation

`HarnessSpec`, `HandoffSpec`, and compile-fail fixtures cover Production/Harness separation, wrong-run,
cross-scope and mismatched-live-broker refusal, signature tampering, rank-2 scope non-escape, and absence of a
caller-supplied scope or key route. The capsule tests assert that store/generation/verb/edge coordinates remain
outside this scope-only value; the host-static full suite closes the sprint.

#### Remaining Work

Implement the call-site adoption after the authenticated-handoff phase exposes the generic capsule producer
and scope-first receiver.

## Phase Remaining Work

Implement Sprint 19.5, then close the live half of the phase gate. The completed sprints' own deliverables are
closed by the host static gate, while the phase also owes two linux-cpu confirmations: rerun the recovery
phase's deterministic interruption matrix with
`cabal test hostbootstrap-core:test:hostbootstrap-core-test --ghc-options=-Werror --test-options='--pattern recovery-interruption'`
from `core/`, then run `hostbootstrap run -- test run all` against live harness infrastructure. Dated evidence
records both results together. This repository's current development host is aarch64-osx.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/harness_workflow.md` — the ownership bracket, the sweep, and the engine.
- `documents/architecture/run_models.md` — execution shape is the lifecycle plan.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the report card, per-variant isolation, and what the static suites cannot
  cover.

**Cross-references to add:**
- `development_plan_standards.md` §§ W, Y, and Z name this phase as the owner of the Harness command consumer
  and assertion engine.
