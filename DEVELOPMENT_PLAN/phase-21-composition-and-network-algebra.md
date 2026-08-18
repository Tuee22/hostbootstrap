# Phase 21 — Composition and network algebra

**Status**: Active
**Depends on**: Phase 16 (cluster lifecycle, budgets, and cordoning)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Supply the scope-indexed endpoint and reachability algebra, the proof-gated blob delivery it
> enables, and the opaque role phase machine a long-running workload is driven by.

## Phase Objective

Two reusable algebras sit above the cluster and below the service surface. The first is network reachability:
an endpoint is indexed by the scope that can reach it, so a client cannot be handed an address its own scope
cannot resolve — and a redirect is only delivered once there is a proof the client can reach the target. The
second is the role phase machine: a long-running workload's lifecycle is an opaque cursor rather than a bag of
callbacks a caller can skip.

## Sprints

### Sprint 21.1: Scope-indexed endpoints and reachability [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Network.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

Make "this client can reach this endpoint" a typed fact.

#### Deliverables

- An endpoint is indexed by the scope that can reach it, so a cluster-only address cannot be handed to a host
  client.
- A reachability proof is produced by observation, not assertion, and carries the scope it was taken in.
- The identity-bound readiness value the proof consumes comes from the canonical-quantities phase, so
  reachability and readiness are one observation rather than two.
- `reachLeaf` is the additive smart constructor that renders the reachability probe through the lower generic
  Lift; it is owned here rather than by the Phase-8 fold contract.

#### Validation

`RegistrySpec` and the network cases cover each scope pairing, the refusal when scopes do not match, and the
exact `reachLeaf` argument shape. A source guard distinguishes the later additive helper from the lower Lift
fold contract.

#### Remaining Work

The complete phase gate.

### Sprint 21.2: Proof-gated blob delivery [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`, `core/hostbootstrap-core/test/RegistryPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

Never redirect a client to something it cannot reach.

#### Deliverables

- A blob route is delivered only behind a settled route proof; liveness of the front door is not evidence that
  the backing store is reachable from the client's scope.
- One finalized registry plan renders the whole configuration as output, including whether redirects are
  enabled, so the configuration a registry receives is the plan's rather than an edit.
- An image push requires a settled route rather than a successful ping.
- `blobUploadSessionLeaf`, `blobUploadPatchLeaf`, `blobUploadFinishLeaf`, and `blobHeadLeaf` are additive
  Lift smart constructors owned by this blob-delivery sprint, not by the lower generic fold.
- `HostBootstrap.Registry` owns `liftSubcommandWithAuth`: registry policy consumes the lower Lift and its
  generic `shellQuoteArgs`; `HostBootstrap.Lift` never imports Registry or its credential type.

#### Validation

`RegistrySpec` and `RegistryPlanSpec` cover the finalized rendering, all four blob leaf argument shapes,
registry-auth forwarding, and the refusal when the route is not settled, with a negative fixture proving an
unreachable configuration is refused rather than redirecting. A source guard pins the `Registry -> Lift`
dependency direction.

#### Remaining Work

Add exact argument-shape coverage for all four blob Lift leaves, rerun the focused registry suites, and run
the complete phase gate. The Registry-owned authenticated entry and `Registry -> Lift` dependency guard are
implemented.

### Sprint 21.3: The opaque role phase machine [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Drive a long-running role through phases a caller cannot skip.

#### Deliverables

- `RolePlan` and `RoleCursor` are opaque; the machine is reached only through a verified activation, then a
  verified role-plan draft, then a one-use lifecycle admission. There is no public callback record, because a
  record lets a caller omit a phase.
- The lease requirement is **derived** from the signed effect ceiling rather than declared, and an exclusive
  branch holds a real kernel lock across acquire-through-drain.
- Every phase transition returns a successor cursor, including on failure, and drain attempts every release and
  aggregates the failures.
- A prerequisite refusal turns at its own phase and acquires nothing; a readiness failure cannot reach serve.

#### Validation

`RoleLifecycleSpec` covers the admission chain, the derived lease requirement, each phase transition including
failures, the aggregate drain, and a live exclusive holder refusing a peer before it acquires anything.

#### Remaining Work

The 2026-08-08 authority audit reopened this sprint. Before it can close:

- make every opaque role-plan, binding, placement, effect-authorization, and phase-cursor identity nominal and
  pin all axes with exact compile-fail evidence;
- replace the reusable prerequisite cursor with a core-owned transition chain that actually yields every
  successor and prevents a second run from the same cursor;
- define and test the asynchronous-exception policy so interruption during a restored callback still reaches
  Drain, and force callback outcomes inside that protection so a delayed exception cannot escape after it;
- make shutdown reporting agree with `roleExitReportOk`, and either implement the promised unknown-receipt
  reprobe before release or narrow the contract;
- extend Phase 13's collision-free bounded admission key with the durable admission/open recovery protocol
  described by the canonical standards: explicit lost-acknowledgement outcomes, identity-preserving
  rehydration of Reserved/Consumed state, and no permanently lost sole cursor after callback interruption; and
- rerun the focused suite and complete phase gate.

Adoption at the `service run` call site remains the service-runtime phase's work.

## Remaining Work

Sprint 21.2 still needs exact argument-shape coverage for its four blob Lift leaves. Sprint 21.3 is reopened
for the role authority, transition, interruption, reporting, receipt-reprobe, and durable-resume gaps listed
above. The phase additionally owns § LL's single crossing renderer: the lift fold is the only place a
frame-crossing argument vector is produced, so the registry's authenticated descent derives from it instead
of choosing between two crossing routes at runtime, and the sanitized lifecycle route derives from it
instead of rendering its own vector for the same layer. The focused suites and a fresh complete phase gate
validate the phase after those lanes close.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/network_reachability.md` — scope-indexed endpoints and proof-gated delivery.
- `documents/architecture/composition_methodology.md` — the role phase machine.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` — using the role machine.

**Cross-references to add:**
- `development_plan_standards.md` § GG and § AA name this phase as the owner of these algebras.
