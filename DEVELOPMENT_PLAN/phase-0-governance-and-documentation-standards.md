# Phase 0 — Governance and documentation standards

**Status**: Done
**Depends on**: nothing
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Establish the metadata standard, the plan tree, and the machine-checked documentation
> validator that every later phase is judged against.

## Phase Objective

Before any code is written, fix how the repository describes itself: one metadata block on every governed
document, one authoritative plan tree, one taxonomy for `documents/`, and one validator that fails the
build when a document drifts from the standard. Governance precedes construction because a standard that
is not enforced is a preference.

## Sprints

### Sprint 0.1: The governed metadata block [Done]

**Status**: Done
**Implementation**: `documents/documentation_standards.md`
**Substrates**: none
**Docs to update**: `documents/documentation_standards.md`, `documents/README.md`

#### Objective

Give every governed document one machine-checkable header.

#### Deliverables

- Each document under `documents/` opens with an `# Title` line, then `**Status**:`, `**Supersedes**:`,
  and `**Referenced by**:`, then a `> **Purpose**:` blockquote.
- YAML front matter is not used, so the header is readable as prose and diffable as text.
- `documents/README.md` is the taxonomy index and names each family's canonical home.

#### Validation

`DocValidatorSpec` asserts the live repository conforms.

#### Remaining Work

None.

### Sprint 0.2: The plan tree and its standards [Done]

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/development_plan_standards.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/rationale.md`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Fix the plan's own structure: one continuous constructive narrative in numerical order.

#### Deliverables

- `development_plan_standards.md` § A–§ J and § II define the doctrine: phase numbers are the execution
  order, the narrative is strictly additive, a design error rewrites the phase that introduced it, and a
  phase declares at most one substrate beyond `linux-cpu`.
- `README.md` carries the single cross-phase status table, one short cell per phase.
- `00-overview.md` explains phase responsibilities and the dependency flow without duplicating status.
- `system-components.md` inventories the implementation surfaces.
- `rationale.md` holds non-normative design justification, including the shapes the project rejects.
- § K–§ HH state the normative technical contracts once, in final form.

#### Validation

The tree is contiguous from `phase-0` with no gaps, and every relative link resolves.

#### Remaining Work

None.

### Sprint 0.3: The documentation validator [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: none
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Make the standard mechanical rather than aspirational.

#### Deliverables

- `validateRepo` checks governed metadata on `documents/`, the taxonomy, naming, and that every relative
  markdown link resolves across `documents/`, `DEVELOPMENT_PLAN/`, and the governed root documents.
- Fenced code blocks are stripped before link checking, so example templates are exempt.
- Every phase document carries a `## Documentation Requirements` section.
- The doctrine checks: a phase's `Depends on` names only strictly lower phases; no phase document uses
  reversal vocabulary; sprint structure and the closed status vocabulary hold; a phase declares at most
  one non-baseline substrate; each phase's status matches its README row; the phase set is contiguous.
- A negative fixture proves every check is non-vacuous.

#### Validation

`DocValidatorSpec` runs `validateRepo` against the live repository and fails on any violation, then runs
the negative fixture. Both execute inside the canonical `cabal test all --ghc-options=-Werror`.

Dated evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), the focused `DocValidatorSpec` passed 2/2,
and the exact phase gate, `cabal test all --ghc-options=-Werror` from `core/`, passed 1426/1426 cases in
67.48 seconds. The negative fixture exercised missing, malformed, duplicate, unmatched, and mismatched
phase-status rows.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/README.md` — the taxonomy index and canonical-home map.

**Engineering docs to create/update:**
- `documents/documentation_standards.md` — the metadata block, taxonomy, and validator contract.

**Cross-references to add:**
- `README.md`, `AGENTS.md`, and `CLAUDE.md` point at the canonical governance homes.
- `DEVELOPMENT_PLAN/README.md` and `00-overview.md` defer doctrine to
  [development_plan_standards.md](development_plan_standards.md).
