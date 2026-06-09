# Phase 0: Documentation and Governance

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-hostbootstrap-core-scaffolding.md](phase-1-hostbootstrap-core-scaffolding.md)

> **Purpose**: Establish the unified documentation and development-plan governance — the
> metadata-block standard, this `DEVELOPMENT_PLAN/` tree, and the documentation validator — so every
> later phase has aligned standards to land against.

## Phase Status

**Status**: Active

Phase 0's **foundational** governance is closed and holds: the governed `documents/` suite carries the
unified metadata block, this `DEVELOPMENT_PLAN/` tree exists in the canonical layout, and the mechanical
documentation validator (`HostBootstrap.DocValidator`) has **landed** and runs through the canonical
code-check. That foundation gates the code phases, so phases 1–7 stay `Active`/`Done` (see
[development_plan_standards.md § A](development_plan_standards.md)). Phase 0 reopens only for the
**expanded doc-coverage** obligation the global-architecture contract adds: the governed suite and
`README.md` must be rewritten to the new architecture, the taxonomy resolved, and the validator extended
into the reusable family doc-floor.

**Remaining Work** (reopened against the global-architecture contract):
- Author/rewrite the governed `documents/` suite and `README.md` to the architecture (the new
  architecture/engineering/operations docs and the rewrites named in their owning phases'
  `## Documentation Requirements`).
- Resolve the taxonomy: add `documents/operations/`, trim `development/` and `reference/` from
  `documents/documentation_standards.md` § Taxonomy and `documents/README.md` (same change).
- Extend `HostBootstrap.DocValidator`: add `snake_case` file-naming and an optional taxonomy check;
  export the per-check functions as a reusable family doc-floor.
- Land the remaining stale-claim corrections (the `dhall-to-json`, baked-binary, and freeze-commit doc
  claims; carried by phases 4/6/12).

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
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`haskell/hostbootstrap-core/test/DocValidatorSpec.hs`
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
