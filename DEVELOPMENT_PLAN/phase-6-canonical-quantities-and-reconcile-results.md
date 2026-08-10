# Phase 6 — Canonical quantities, readiness, and reconcile results

**Status**: Done
**Depends on**: Phase 5 (operator, root, and command authority)
**Substrates**: none (static)
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Supply one canonical parser for every quantity, the provider-neutral capacity and cordon
> foundation, opaque generative readiness bound to a hidden probe, and the ownership- and phase-indexed
> result type every reconciliation returns.

## Phase Objective

Two kinds of value are pervasive above this phase: a quantity someone wrote down, and an observation
someone made. Both are places where a second representation causes silent disagreement — two parsers that
round differently, or a readiness flag a caller can set. This phase gives each exactly one canonical form,
gives capacity preflight and provider sizing one pure vocabulary, and gives reconciliation a result type
that distinguishes what we own from what we merely found.

## Sprints

### Sprint 6.1: Canonical quantities and the provider-neutral cordon foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/CordonSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`

#### Objective

One parser, one exact unit model, and one pure capacity/sizing vocabulary for every provider consumer.

#### Deliverables

- Opaque `ResourceBudget` retains positive bounded CPU plus memory/storage in canonical units; callers cannot
  construct a zero, negative, or overflowed budget directly.
- `parseQuantity` is total: malformed, inexact, or unsupported input returns a descriptive refusal naming the
  input rather than a default or rounded value.
- `HostCapacity`, `CapacityReadPlan`, `verifyBudget`, and `verifyHostBudget` form the provider-neutral
  preflight foundation; capacity observation is separate from mutation authority.
- Lima, Colima, Incus, WSL2, and kind-node sizing renderers consume those same exact quantities, and a
  provider that cannot represent a hard ceiling exactly refuses it rather than rounding upward.
- `StorageCordonResult` states the supported wall mechanism or the typed bare-Linux unsupported decision;
  the pure result grants no authority to apply a provider wall.

#### Validation

`CordonSpec` covers parsing/refusal, capacity and reserve overflow, provider exactness, the storage-wall
matrix, and fail-closed argument construction. A source guard permits the exposed
`HostBootstrap.Cluster.Cordon.Foundation` to import only the lower `HostConfig`, `HostTool`, and `Substrate`
families from `HostBootstrap.*`.

Dated evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), focused `CordonSpec` passed 54/54 and
`BudgetSpec` passed 19/19 under `-Werror`; the exact phase gate
`cabal test all --ghc-options=-Werror` from `core/` then passed 1463/1463.

#### Remaining Work

None. Phase 7 owns the configuration-envelope facade and `fitsBudget`; Phase 12 owns the plan-indexed
proof families.

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
- `documents/engineering/resource_budgeting.md` — opaque canonical-unit `ResourceBudget`, capacity
  verification, and exact sizing renderers.
- `documents/engineering/applied_cordon.md` — how the lower sizing and storage policies are applied, with
  plan-indexed proof consumption attributed to Phase 12.

**Cross-references to add:**
- `development_plan_standards.md` § O and § CC name this phase as the owner of the provider-neutral quantity,
  capacity, storage-policy, and readiness contracts.
