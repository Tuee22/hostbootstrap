# Phase 14: Composable-Operation Algebra and Composition Methodology

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Frame `hostbootstrap-core`'s foundational composition model — a binary composes
> **operations** and crosses execution-context boundaries by invoking itself (the self-reference lift,
> Phase 11) — and document the deploy ≡ business-logic unification, leaving the concrete L1 business-logic
> primitives out of scope.

## Phase Status

**Status**: Done

The composition **methodology** is documented and the foundational primitive (the self-reference lift,
`HostBootstrap.Lift`) is landed in [Phase 11](phase-11-incus-host-provider.md) (Sprint 11.5). This phase
owns the broader framing: the operation taxonomy, the deploy ≡ business-logic unification, the foundational
principles, and the L0 role-lifecycle skeleton on which L1 builds the concrete business-logic primitives
(roles, topologies, policies). Sprint 14.1 (the methodology + cookbook docs and the § U doctrine rewrite)
is `Done`; Sprint 14.2 (the L0 role-lifecycle skeleton `HostBootstrap.RoleLifecycle`, consumed by the
demo's F2 role) is `Done` — the operation *interface* is the documented taxonomy, not a Haskell typeclass
(reconcilers stay `HostConfig -> IO ()`, no threaded context). The concrete bus/store/role primitives are
**L1 (`daemon-substrate`)** work, out of scope here; this phase ships only the L0 substrate and the
methodology.

## Phase Objective

Land the foundational composition model in `hostbootstrap-core` and its documentation: operations as the
composable unit, the self-reference lift as the context-crossing operation (Phase 11), the deploy ≡
business-logic unification, and the L0 role-lifecycle skeleton — so a consumer composes any chain of
operations across contexts through the four-stream merge without L0 changes (see
[development_plan_standards.md § T, § U](development_plan_standards.md)).

## Sprints

### Sprint 14.1: Composition methodology and cookbook docs [Done]

**Status**: Done
**Implementation**: `documents/architecture/composition_methodology.md`, `documents/engineering/composition_patterns.md`, `documents/engineering/authoring_project_binaries.md`, `DEVELOPMENT_PLAN/development_plan_standards.md` (§ U)
**Docs to update**: `documents/README.md`, `README.md`

#### Objective

Document the composable-operation algebra, the self-reference lift, the deploy ≡ business-logic
unification, the foundational principles, and the L0/L1/L2 layering, and rewrite § U from the two-case
`HostTarget` to the n-level lift.

#### Deliverables

- `composition_methodology.md` (architecture, authoritative): the operation taxonomy, the lift, the
  deploy ≡ business-logic unification, the three foundational principles, and the layering.
- `composition_patterns.md` (engineering): the cookbook of context topologies, operation kinds, and
  business-logic shapes.
- `authoring_project_binaries.md` (engineering): the authoring how-to for a new consumer.
- § U rewritten (`Local | InVM` → the n-level self-reference lift); the new docs indexed and backlinked.

#### Validation

- `HostBootstrap.DocValidator` (run through the code-check) passes on all new/edited docs (metadata,
  TL;DR for architecture, resolving relative links, taxonomy). `cabal test` passes.

#### Remaining Work

None.

### Sprint 14.2: The role-lifecycle skeleton [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`, `core/hostbootstrap-core/test/RoleLifecycleSpec.hs`, `demo/src/HostBootstrapDemo/Role.hs`
**Docs to update**: `documents/architecture/composition_methodology.md`, `documents/architecture/run_models.md`

#### Objective

Land the L0 role-lifecycle skeleton (Load → Prereq → Acquire → Ready → Serve → Drain → Exit) with callback
injection — the `HostDaemon` run-model's substrate on which L1 builds concrete roles. The operation
*interface* is the documented taxonomy (a conceptual unification), **not** a Haskell typeclass:
reconcilers stay `HostConfig -> IO ()` (no threaded context), per the composition methodology.

#### Deliverables

- `HostBootstrap.RoleLifecycle`: the `RolePhase` enum + the pure `rolePhases` ordering, the `RoleSpec`
  record (acquire/serve/drain callbacks), and `runRole` (drives the lifecycle, draining via `finally`).
- A real consumer: the demo's F2 role (`HostBootstrapDemo.Role`) drives `roleServe` through `runRole`, so
  the skeleton is exercised, not dead code. The concrete bus/store/role primitives (declared topologies,
  batching/scheduler policy, the lifecycle reconciler, the WAN-egress hydrator) remain **L1
  (`daemon-substrate`)** work, out of scope.

#### Validation

- `RoleLifecycleSpec` asserts the phase ordering and that `runRole` acquires→serves→drains (and drains
  even when serving throws). The demo's `role serve`/`submit` round-trips through `runRole`. `cabal test`
  passes (134 tests).

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/composition_methodology.md` - the operation algebra, the self-reference lift,
  and the deploy ≡ business-logic unification (created, Sprint 14.1).

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` - the shape cookbook (created).
- `documents/engineering/authoring_project_binaries.md` - the authoring how-to (created).

**Cross-references to add:**
- `documents/README.md` indexes the three new docs; `system-components.md` carries the
  `HostBootstrap.Lift` row; `development_plan_standards.md` § U is rewritten to the n-level lift.
