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
- The doctrine checks a field can express: a phase's `Depends on` names only strictly lower phases; no
  phase document uses reversal vocabulary; sprint structure and the closed status vocabulary hold; a phase
  declares at most one non-baseline substrate; each phase's status matches its README row; the phase set
  is contiguous. The doctrine that lives in prose rather than in a field is Sprint 0.4's.
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

### Sprint 0.4: The doctrine checks a green build can hide [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`,
`DEVELOPMENT_PLAN/development_plan_standards.md`
**Substrates**: none
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Check the parts of § A, § C and § I that a `Depends on` field cannot express, so a plan that reads
correct and orders wrong fails the build rather than passing it.

#### Deliverables

- One section parser is what every structural check reads. A markdown section runs to the next heading of
  any level, and a level-two heading closes the enclosing sprint — so a phase's trailing
  `## Remaining Work` belongs to the phase rather than to the last sprint above it, which is exactly the
  attribution a sprint-only split gets wrong and the reason those checks were vacuous where it mattered.
- `checkRemainingWorkOrdering`: no `Remaining Work` section cites a higher-numbered phase. This is § A's
  rule where it is actually broken — "this closes when phase 15 lands" is the forbidden claim in prose,
  and the `Depends on` field never sees it. The scope is the precision: a forward link in
  `## Phase Objective` or `#### Validation` says who owns what and stays legal, because no reading of a
  sentence separates the two claims and the section it sits in does.
- `checkActivePhaseRemainingWork`: an `Active` phase carries a non-empty `## Remaining Work`, and the one
  drifted spelling reports as its own correction rather than as a missing section.
- `checkDoneSprintRemainingWork`: a `Done` sprint has the section and it begins "None." A sprint that
  still owes something is not done, and an owed *live* confirmation is listed by the acceptance phase
  declaring the hardware (§ II) rather than parked in a closed sprint.
- `checkLegacyLedger` gains an arity clause reading the row's `Deleted by` cell alone, so a phase cited in
  the `Why` column neither satisfies nor inflates it. Two owners is the same failure as none: neither
  phase's completion empties the row (§ I).
- `checkContractOwnership`: every contract beneath `## hostbootstrap-Specific Contracts` opens with an
  `**Owning phase**:` line. Inferring an owner from any phase a section happens to cite is not the same
  claim — § O mentions ten phases and is owned by one.
- Each guard's negative fixture proves it fires, and the two scoped guards additionally assert an
  **absence** — a forward link in a `#### Validation` section and a bare citation inside a contract must
  produce no violation — so the scoping is proved rather than assumed.

#### Validation

`DocValidatorSpec` against the live repository and against the negative fixture, inside
`cabal test all --ghc-options=-Werror` from `core/`.

Each guard was proved non-vacuous against the live tree before its fix landed: the ordering guard reported
thirteen forward citations across seven phase documents, the Active-phase guard five missing sections and
two drifted headings, the Done-sprint guard one declared-work section and ten missing ones, the ledger
guard three two-owner rows, and the contract guard fifteen unowned contracts. The tree carries none of
them now.

Dated evidence: on 2026-08-18, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,951/1,951 in 241.11 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

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
