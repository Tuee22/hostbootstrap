# Phase 6 — Canonical quantities, readiness, and reconcile results

**Status**: Done
**Depends on**: Phase 5 (operator, root, and command authority)
**Substrates**: none (static)
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Supply one canonical parser for every quantity, opaque generative readiness bound to a
> hidden probe, and the ownership- and phase-indexed result type every reconciliation returns.

## Phase Objective

Two kinds of value are pervasive above this phase: a quantity someone wrote down, and an observation
someone made. Both are places where a second representation causes silent disagreement — two parsers that
round differently, or a readiness flag a caller can set. This phase gives each exactly one canonical form,
and gives reconciliation a result type that distinguishes what we own from what we merely found.

## Sprints

### Sprint 6.1: One canonical quantity parser [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`

#### Objective

One parser, one rounding rule, one rendering.

#### Deliverables

- CPU, memory, and storage quantities have one canonical type each, parsed and rendered in one place.
- Parsing is total: a malformed quantity is a typed refusal naming the input, never a default.
- Arithmetic on quantities is closed over the canonical types, so a unit mismatch is a type error.
- `EffectiveBudget`, `PlannedWorkloadSet`, `VerifiedWorkloadFit`, `BudgetPartition`, and `ResourceSlice` are
  opaque, so a fit is a proof rather than an assertion.

#### Validation

`BudgetSpec` covers the parse/render round trip, each refusal, and the fit proofs.

#### Remaining Work

None.

### Sprint 6.2: Opaque readiness and total probes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/test/ReadinessSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Make readiness an observation, not a flag.

#### Deliverables

- A readiness value is opaque, generative, and indexed by lifecycle scope, resource instance, and the exact
  dependency a hidden probe selected. A caller cannot construct one.
- Every probe is **total**: it returns ready, not-ready-with-cause, or unsupported — never an exception and
  never a silent false.
- A readiness value carries the version at which it was observed, so a stale one can be refused rather than
  re-used.
- Readiness is not effect authority: holding one authorizes nothing.

#### Validation

`ReadinessSpec` covers each probe outcome, the staleness refusal, and the absence of a public constructor.

#### Remaining Work

None.

### Sprint 6.3: Ownership- and phase-indexed reconcile results [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Distinguish what we own from what we found, in the type.

#### Deliverables

- `ResourceHandle scope planId id resource ownership phase` indexes a handle by ownership (`Managed`,
  `Unmanaged`, `Unclassified`) and lifecycle phase.
- `ReconcileResult` has exactly two constructors: `ManagedResult` carries a managed handle, an
  `OwnershipReceipt`, and a `ChangeView`; `ForeignResult` carries only an `Unmanaged` handle and a
  `ForeignObservation`. A foreign handle **cannot type-check at teardown**, so a stranger's resource is
  structurally un-deletable rather than protected by a runtime check.
- `ManagedResult Unchanged` retains its handle and receipt, so an idempotent reconcile is still ownership.
- Failure is structured: `Conflict`, `SafetyRefusal`, `Unsupported`, and `Failure` are distinct, each with
  its own detail and retry disposition.
- Explicit adoption requires matching opaque authority and reports `Changed Adopted`; it is never implicit.

#### Validation

`ReconcileSpec` covers each result and failure branch, the retry dispositions, and that a foreign handle is
rejected at teardown by the type checker.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/readiness.md` — opaque generative readiness and total probes.
- `documents/architecture/lifecycle_state_model.md` — the ownership/phase index and the result algebra.

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` — the canonical quantity types and the fit proofs.
- `documents/engineering/applied_cordon.md` — how the budget proofs are consumed.

**Cross-references to add:**
- `development_plan_standards.md` § O and § CC name this phase as the owner of the quantity and readiness
  contracts.
