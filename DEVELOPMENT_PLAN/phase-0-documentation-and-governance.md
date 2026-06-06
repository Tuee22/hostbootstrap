# Phase 0: Documentation and Governance

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-1-hostbootstrap-core-scaffolding.md](phase-1-hostbootstrap-core-scaffolding.md)

> **Purpose**: Establish the unified documentation and development-plan governance — the
> metadata-block standard, this `DEVELOPMENT_PLAN/` tree, and the documentation validator — so every
> later phase has aligned standards to land against.

## Phase Status

**Status**: Active

This phase is in progress: the current documentation refactor converts the governed `documents/`
suite to the unified standard and creates this `DEVELOPMENT_PLAN/` tree. No code-writing phase may be
marked `Active` or `Done` until Phase 0 closes (see
[development_plan_standards.md § A](development_plan_standards.md)).

### Remaining Work

- Finish converting every governed `documents/**.md` from YAML front-matter to the metadata block
  (Sprint 0.1).
- Land the new `documents/architecture/*` and `documents/engineering/*` target-architecture docs
  named in later phases (Sprint 0.2).
- Implement the mechanical documentation validator (Sprint 0.3); until it lands, conformance is
  manual review.

## Phase Objective

Bring `hostbootstrap`'s governance onto the same shape its consumers use: metadata blocks on every
governed doc, the canonical `documents/` taxonomy with `languages/` declared as a documented extra
category, governed root-document blocks on `README.md` / `AGENTS.md` / `CLAUDE.md`, the
`DEVELOPMENT_PLAN/` phase/sprint format with honest completion tracking, and a mechanical validator
that enforces the structure. The governed `documents/` and `README.md` are rewritten present-tense to
the target Haskell-core + thin-Python architecture; honest current-vs-target status lives here and in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprints

### Sprint 0.1: Convert documents/ to the metadata-block standard [Active]

**Status**: Active
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

Manual structural review against the standard until the validator (Sprint 0.3) lands.

#### Remaining Work

- Confirm every existing doc under `documents/engineering/` and `documents/languages/` is converted.

### Sprint 0.2: Create the DEVELOPMENT_PLAN tree [Active]

**Status**: Active
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

Manual review that the layout matches the standard and the honesty check holds: no `documents/` or
`README.md` claims a target capability is `Done`.

#### Remaining Work

- Keep this tree in sync as the target-architecture `documents/` pages land in Sprint 0.2's sibling
  doc work.

### Sprint 0.3: Documentation validator [Blocked]

**Status**: Blocked
**Blocked by**: phase-1 (the validator ships as a `hostbootstrap-core` quality-gate deliverable that
needs the cabal package to live in)
**Docs to update**: `documents/documentation_standards.md`,
`DEVELOPMENT_PLAN/phase-1-hostbootstrap-core-scaffolding.md`

#### Objective

Implement the mechanical documentation validator named as a Phase-0 deliverable. It runs through the
project's canonical code-check and verifies metadata lines, broad-doctrine structure, governed
root-document metadata, relative-link resolution, the root `README.md` references to both
`documents/` and `DEVELOPMENT_PLAN/`, and that every phase document retains its
`## Documentation Requirements` section.

#### Deliverables

- A validator wired into the canonical code-check, with the checks listed in
  `documents/documentation_standards.md § Validation`.

#### Validation

The validator passes against the converted `documents/` suite and this `DEVELOPMENT_PLAN/` tree.

#### Remaining Work

- All of it; blocked until `hostbootstrap-core` exists to host the gate.

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
