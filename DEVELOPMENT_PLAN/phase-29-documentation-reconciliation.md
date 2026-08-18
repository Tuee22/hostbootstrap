# Phase 29 — Documentation reconciliation and drift guards

**Status**: Planned
**Depends on**: every preceding phase
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: After the narrative is fully built, reconcile the governed `documents/` suite, comments, and help
> text with what the code actually does — and install the guards that keep them reconciled.

## Phase Objective

The governed documents describe supported behaviour, and § J requires them to agree with the plan. While phases
are still open they legitimately describe contracts that are not yet fully wired. This phase is the sweep that
closes that gap once, and then makes it mechanically hard to reopen.

It is last because it is the only phase whose subject is every other phase. It adds nothing to the build.

## Sprints

### Sprint 29.1: Reconcile the governed documents [Planned]

**Status**: Planned
**Implementation**: `documents/**`
**Substrates**: none
**Docs to update**: every governed document

#### Objective

Make each governed document describe what the code does.

#### Deliverables

- Every architecture document's contracts match the implemented surfaces, with no target-only statement left
  presented as current behaviour.
- Every engineering document's commands and paths are the real ones.
- Each document's `**Referenced by**` list is accurate, and each family's canonical home is the one
  `documents/README.md` names.
- Every `documents/` reference to a phase is **by name and link** (§ J). A bare number in prose is an
  execution position that a renumbering falsifies, and a bare *sprint* number falsifies faster still —
  a citation naming a sprint the owning phase no longer declares points at nothing at all.
- Duration and capacity figures are the observed ones, and any figure another document *derives* from them is
  recomputed rather than left resting on a stale input.
- [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) is empty, because every shape it named
  has been deleted by the phase that owned it. An empty ledger is this phase's closing condition for that
  document, not a document to keep populated.
- Every ledger row that still exists names a deleting phase that resolves, which `DocValidatorSpec`
  enforces mechanically — an unowned row is how a ledger rots into the repair log § I forbids.

#### Validation

`DocValidatorSpec` plus a read-through of each family against its implementation. The validator checks the
ledger's rows resolve; the read-through checks the ledger is empty.

#### Remaining Work

Not started; it runs after the preceding phases close.

### Sprint 29.2: Reconcile comments and help text [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/**`, `demo/src/**`, `hostbootstrap/**`
**Substrates**: none
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Make in-code references and operator-visible text accurate.

#### Deliverables

- Every source comment that references the plan cites a phase by **name and link**, never by number, so a
  renumbering does not falsify it (§ J).
- Command help text, metavariables, and refusal messages name the typed vocabulary the code actually uses.
- A refusal message names the remedy where one exists, and names the route forward where recovery is possible.

#### Validation

A grep-backed check that no source comment carries a bare phase number, plus `CLISpec` over the help text.

#### Remaining Work

Not started.

### Sprint 29.3: Install the drift guards [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Make the reconciled state mechanically hard to lose.

#### Deliverables

- Absence guards (§ I) for each shape [rationale.md](rationale.md) records as wrong, each naming its rationale
  entry.
- The doctrine checks are enforced rather than reviewed: dependency ordering, reversal vocabulary, sprint
  structure, the substrate budget, status harmony with the README table, and contiguous phase numbering.
- The § KK script and interpreter-text guards, the § LL frame-table guards, and the § MM path-frame guards
  are part of that set, so a reintroduced script, a second crossing renderer, or a host-grammar check over a
  guest path fails the gate rather than a review.
- A guard that fires names the phase to rewrite, not a cleanup task to add — because under § A there is no
  cleanup task.

#### Validation

`DocValidatorSpec`'s negative fixture proves each guard is non-vacuous.

#### Remaining Work

Not started. The doctrine checks themselves are delivered by the governance phase; this sprint adds the
architecture-specific absence guards on top of them.

## Documentation Requirements

**Architecture docs to create/update:**
- every document under `documents/architecture/` — reconciled against the implemented surfaces.

**Engineering docs to create/update:**
- every document under `documents/engineering/` and `documents/operations/` — reconciled against the real
  commands and observed figures.

**Cross-references to add:**
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `DEVELOPMENT_PLAN/README.md`, `00-overview.md`, and
  `system-components.md` all agree on the phase names and defer status to the README table.
