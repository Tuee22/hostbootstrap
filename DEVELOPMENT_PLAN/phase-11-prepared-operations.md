# Phase 11 — Prepared operations and preconditions

**Status**: Done
**Depends on**: Phase 10 (versioned sessions, the project journal, and durable fences)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Make every external effect require a value that could only have been minted by one protected
> compare-and-swap taken immediately before it, over freshly re-probed evidence.

## Phase Objective

This is the gate every reservation, mutation, and delete passes through. An adapter does not accept a request;
it accepts a `PreparedOperation` paired with the `PreparedPreconditions` minted with it, and the pair records
the exact target identity, generation, operation key, precondition set, call digest, session, fence, attempt,
and journal version. Anything stale, replaced, or not-ready yields no pair at all.

The point is not extra checking. It is that a caller has no way to *express* an effect without the pair, so
"the preconditions were verified before the call" is a fact about the type rather than a discipline.

## Sprints

### Sprint 11.1: The prepared gate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`, `core/hostbootstrap-core/test/PrepareFixture.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

One unforgeable gate whose sole producer performs the durable unknown-phase compare-and-swap.

#### Deliverables

- `PreparedGate` is opaque and its sole producer records the durable unknown state, so the record that an
  attempt *may* have happened always precedes the attempt.
- The gate carries the attempt number and journal version, so `withPreparedOperation` reads them off it rather
  than accepting two integers a caller could mismatch.
- A gate recorded under another plan digest or another operation key is refused.
- The consumed journal version cannot authorize a second prepare or a close.

#### Validation

`LifecycleSpec` covers the mint, the durable-unknown ordering, and each refusal. `PrepareFixture` supplies the
recorded states.

#### Remaining Work

None.

### Sprint 11.2: The prepare compare-and-swap [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Revalidate everything, re-probe everything, then mint the only matching pair.

#### Deliverables

- One protected compare-and-swap revalidates the exact project-mode, broker, and authority epochs; the bound
  lease; the active revision with no migration freeze; the open project state; the verb, phase, frame, and
  session; the current fence; the journal version and phase; the operation key; the sealed precondition set;
  and the call digest.
- It re-runs **every** target and dependency probe and every conditional version itself. Stale, replaced, or
  not-ready evidence returns no `PreparedOperation`.
- The sealed `OperationPreconditionSet` has one producer, which runs each member's probe itself, so a caller
  cannot select, omit, or retain a dependency observation.
- An operation's edge set is the exact ordered resource-bearing prefix of the plan, derived by traversal rather
  than declared.
- The successful outcome is a `PreparedOperation`/`PreparedPreconditions` pair the adapter accepts **together**,
  plus the fresh-versioned successor session, project state, and revision permit.
- Every terminal observation returns `OperationAdvance` on success or a typed failure; its eliminator yields the
  result only with the sole successor state/permit pair. A retained readiness value or either half of the pair
  alone is not effect authority.

#### Validation

`LifecycleSpec` covers each revalidation branch, the re-probe, the pair requirement, and the eliminator.
Compile-fail fixtures reject either half alone, a retained readiness value, and a pair minted for another
target or operation.

#### Remaining Work

None.

### Sprint 11.3: The plan-minted execution descriptor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Protected.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Give a step a value that names its own node, so it can reach a gate.

#### Deliverables

- `StepExecution scope planId` is minted only by the plan and carries the plan digest, the step's own operation
  key and frame, and its exact ordered edge set.
- It has no public constructor, so it exists only inside a real interpretation of a real validated plan.
- The `scope` and `planId` indices are universally quantified at the action, so an action sees them as skolems
  it cannot choose — which is what makes the pairing with a gate's index-carrying values a type-check rather
  than a convention.
- An action derives its node from the descriptor rather than reconstructing it, so the plan and the effect
  cannot disagree about which node ran.
- `withStepPreparedGate` is the descriptor's route to the prepare compare-and-swap: it reads the plan digest
  and the operation key **off the descriptor**, so a step reaches exactly one gate — its own — and cannot
  name a sibling node's operation. It refuses a descriptor whose plan digest is not the session's, because
  those indices are phantom on the session side and would otherwise unify.
- `mkRecordName` is the one injective encoding by which a *namespaced* identity reaches the store's key
  alphabet. Both identities the gate needs are namespaced — a plan operation key (`core:deploy-kind`) and a
  plan digest (`<specDigest>:<planBytesDigest>`) — so before it, neither could name a durable record at all
  and a caller had to invent a lossy sanitizer. Its image and its plain domain are disjoint, so two distinct
  identities can never share one durable phase record.

#### Validation

`ChainSpec` covers the descriptor's contents and the absence of a public constructor. `SessionSpec` covers
the route: a step reaching the gate for its own operation and the encoded record it lands on, the
cross-plan refusal, and the injectivity guard that refuses a plain component shaped like an encoded one.
`cabal test all --ghc-options=-Werror` from `core/` passed 944/944 on 2026-08-05 (aarch64-osx, GHC 9.12.4).

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — the prepare compare-and-swap and the prepared pair.
- `documents/architecture/composition_methodology.md` — the plan-minted execution descriptor.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the prepare kill-point and compile-fail fixtures.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § CC name this phase as the owner of the prepare gate.
