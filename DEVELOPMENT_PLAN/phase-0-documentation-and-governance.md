# Phase 0: Documentation and Governance

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-hostbootstrap-core-scaffolding.md](phase-1-hostbootstrap-core-scaffolding.md)

> **Purpose**: Establish the unified documentation and development-plan governance — the
> metadata-block standard, this `DEVELOPMENT_PLAN/` tree, and the documentation validator — so every
> later phase has aligned standards to land against.

## Phase Status

**Status**: Done

Phase 0's governance is closed and holds. The **foundational** deliverables — the unified
metadata-block standard across the governed `documents/` suite, this `DEVELOPMENT_PLAN/` tree in the
canonical layout, and the mechanical documentation validator (`HostBootstrap.DocValidator`) running
through the canonical code-check — landed first and gate the code phases (see
[development_plan_standards.md § A](development_plan_standards.md)). The expanded doc-coverage
obligations that reopened Phase 0 are also closed: the family doc-floor and taxonomy gate (Sprint 0.4)
and the **doctrine-clarity sweep** (Sprint 0.5) — making two load-bearing doctrines read unmistakably
across the governed suite (the Python wrapper does only the minimum to **build** the binary, and the
project binary is **never blocked by an un-installed dependency**, the purpose of the `ensure` suite,
with the Python host minimums as the **only** hard fail-fast surface) and reconciling the
`system-components.md` inventory to the now-`Done` Phases 6 and 9. All five sprints are `Done` with no
remaining work, so this phase is closed. Per § A it may **reopen** to `Active` if a future architecture
contract adds a new doc-coverage obligation, without reverting any already-implemented code phase.

## Phase Objective

Bring `hostbootstrap`'s governance onto the same shape its consumers use: metadata blocks on every
governed doc, the canonical `documents/` taxonomy with `languages/` declared as a documented extra
category, governed root-document blocks on `README.md` / `AGENTS.md` / `CLAUDE.md`, the
`DEVELOPMENT_PLAN/` phase/sprint format with honest completion tracking, and a mechanical validator
that enforces the structure. The governed `documents/` and `README.md` are rewritten present-tense to
the target Haskell-core + thin-Python architecture; honest current-vs-target status lives here and in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprints

### Sprint 0.1: Convert documents/ to the metadata-block standard [Done]

**Status**: Done
**Implementation**: `documents/documentation_standards.md`, `documents/**/*.md`
**Docs to update**: `documents/documentation_standards.md`, `documents/README.md`

#### Objective

Rewrite `documents/documentation_standards.md` to the unified metadata-block standard, then convert
every existing governed doc from YAML front-matter to the metadata block, make links relative, and
add `Referenced by` lines. Declare `languages/` as a documented extra category alongside the five
canonical categories.

#### Deliverables

- `documents/documentation_standards.md` defining the metadata block, the governed root block, the
  taxonomy (with `languages/` named), and the content/brevity rules.
- Every `documents/**.md` carries `Status` / `Supersedes` / `Referenced by` and a purpose
  blockquote; in-repo links are relative; cross-repo links are absolute URLs.

#### Validation

The `HostBootstrap.DocValidator` gate (Sprint 0.3) checks the metadata block on every governed
`documents/**.md`; `cabal test` passes against the converted suite.

#### Remaining Work

None.

### Sprint 0.2: Create the DEVELOPMENT_PLAN tree [Done]

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/phase-*.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `README.md`, `documents/README.md`

#### Objective

Create the canonical `DEVELOPMENT_PLAN/` layout per
[development_plan_standards.md § E](development_plan_standards.md): the orientation `README.md`, the
`00-overview.md` narrative, the `system-components.md` inventory, the phase files (Phase 0 `Active`,
Phases 1–7 `Blocked`), and the `legacy-tracking-for-deletion.md` ledger.

#### Deliverables

- The full file set named in the canonical folder model, each carrying the required metadata block
  and (for phase files) a closing `## Documentation Requirements` section.
- `00-overview.md`, the phase files, and `system-components.md` use the same phase names and
  current-state claims.

#### Validation

The `HostBootstrap.DocValidator` gate checks that every phase file retains its
`## Documentation Requirements` section and that all phase-plan links resolve; the layout matches the
canonical folder model. The honesty check holds: no `documents/` or `README.md` claims a target
capability is `Done`.

#### Remaining Work

None.

### Sprint 0.3: Documentation validator [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Docs to update**: `documents/documentation_standards.md`,
`DEVELOPMENT_PLAN/phase-1-hostbootstrap-core-scaffolding.md`

#### Objective

Implement the mechanical documentation validator named as a Phase-0 deliverable. It runs through the
project's canonical code-check and verifies metadata lines, broad-doctrine structure, governed
root-document metadata, relative-link resolution, the root `README.md` references to both
`documents/` and `DEVELOPMENT_PLAN/`, and that every phase document retains its
`## Documentation Requirements` section.

#### Deliverables

- `HostBootstrap.DocValidator` (`validateRepo`, `findRepoRoot`, `Violation`) implements the checks
  listed in `documents/documentation_standards.md § Validation`.
- `DocValidatorSpec` wires it into the `hostbootstrap-core-test` suite so `cabal test` (the canonical
  Haskell code-check) fails on drift. The spec carries a negative case proving each check is not
  vacuous.

#### Validation

`cabal test` passes: the validator reports zero violations against the converted `documents/` suite,
the governed root documents, and this `DEVELOPMENT_PLAN/` tree, and the negative case confirms it
flags missing metadata, unresolved links, and missing sections.

#### Remaining Work

None.

### Sprint 0.4: Family doc-floor and taxonomy gate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`, `documents/documentation_standards.md`
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Extend the mechanical validator into the reusable family doc-floor the global-architecture contract
reopened Phase 0 for: mechanical `snake_case` file-naming under `documents/`, a taxonomy check that
rejects any top-level category outside the declared set, and exported per-check functions so the same
floor can be reused across the project family.

#### Deliverables

- `checkNaming` gates lowercase `snake_case` file naming under `documents/` (only `README.md` is
  exempt); `checkTaxonomy` rejects any `documents/` top-level category not in `allowedTaxonomy`
  (`architecture`, `engineering`, `operations`, `languages`).
- The per-check functions (`checkGovernedMeta`, `checkRootDoc`, `checkBroadDoctrine`,
  `checkDocRequirements`, `checkLinks`, `checkReadmeRefs`, `checkNaming`, `checkTaxonomy`) and
  `allowedTaxonomy` are exported from `HostBootstrap.DocValidator`.
- `documents/documentation_standards.md § Validation` lists the two new gated checks and the exported
  floor.

#### Validation

`cabal test` passes: the validator reports zero violations against the converted suite, and the
`DocValidatorSpec` negative case proves the naming and taxonomy checks are not vacuous (a `BadName.md`
and a `documents/reference/` category are both flagged).

#### Remaining Work

None.

### Sprint 0.5: Doctrine-clarity sweep and inventory reconciliation [Done]

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/development_plan_standards.md` (§§ L/M/C),
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/system-components.md`,
`documents/engineering/ensure_reconcilers.md`, `documents/engineering/prerequisites.md`,
`documents/architecture/python_haskell_boundary.md`, `documents/operations/demo_runbook.md`, `README.md`
**Docs to update**: the governed suite, `README.md`, and the plan docs above

#### Objective

Make two load-bearing doctrines read unmistakably across every governed doc, and reconcile the
inventory to the now-`Done` Phases 6 and 9: (1) the Python wrapper does only the **minimum to build the
project binary**; (2) the project binary is **never blocked by a dependency that simply isn't
installed** — the purpose of the `ensure` suite (install-and-verify) — with the Python host minimums as
the **only** hard fail-fast surface (a reconciler's only fail-fast is a wrong-host misuse, not an absent
dependency).

#### Deliverables

- `§ L` leads with the never-blocked purpose and names the only-fail-fast surface; `§ M` states the
  wrapper's minimum-to-build role and cross-links `§ L`; `§ C` adds the real-run/real-build-gated
  `Active` clause (in scope, open — never out of scope).
- `ensure_reconcilers.md` and `prerequisites.md` TL;DRs **lead** with "never blocked by an un-installed
  dependency; the only fail-fast surface is the host minimums"; `python_haskell_boundary.md` states it in
  the TL;DR + ownership matrix and adds the binary-owned lifecycle rows (incus VM, webservice, e2e,
  teardown).
- `README.md` and the `DEVELOPMENT_PLAN/README.md` Validation Policy state both doctrines and the
  two-gate model; `system-components.md` no longer claims the bootstrapper is un-converged or the cordon
  un-applied (reconciled to Phases 6/9 `Done`); the demo runbook shows the full hostbootstrap-owned
  a→f lifecycle including teardown.

#### Validation

- `cabal test` passes (the `HostBootstrap.DocValidator` gate keeps every governed doc's metadata, links,
  naming, taxonomy, and `## Documentation Requirements` conformant). A manual read confirms the TL;DRs
  lead with the doctrine and no stale state claim remains.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - module surface + command-tree extension
  contract
- `documents/architecture/python_haskell_boundary.md` - thin bootstrapper vs core ownership

**Engineering docs to create/update:**
- `documents/documentation_standards.md` - the metadata-block standard and taxonomy
- `documents/README.md` - the suite index

**Cross-references to add:**
- `README.md` references both `documents/` and `DEVELOPMENT_PLAN/`
- this `DEVELOPMENT_PLAN/` tree and the governed `documents/` suite agree on current-state status
