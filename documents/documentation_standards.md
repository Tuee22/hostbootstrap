# Documentation Standards

**Status**: Authoritative source
**Supersedes**: prior YAML-front-matter documentation convention for this repository
**Referenced by**: [README.md](README.md), [../README.md](../README.md), [../DEVELOPMENT_PLAN/development_plan_standards.md](../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: Define how the governed `documents/` suite is structured, updated, and kept aligned
> with `DEVELOPMENT_PLAN/`, `README.md`, and the `hostbootstrap` implementation.

## TL;DR

- `documents/` is the only canonical documentation root for `hostbootstrap`.
- Every governed doc starts with a metadata block (`Status` / `Supersedes` / `Referenced by` /
  purpose blockquote); root docs use the governed-root block (`Canonical homes`).
- Broad doctrine docs use stronger structure: summary first, an explicit `Current Status` note
  when current and target behavior mix, and a `Validation` section when a gate proves the
  contract.
- This standard matches the governance shape used by the consuming projects
  ([`daemon-substrate`](https://github.com/Tuee22/daemon-substrate),
  [`infernix`](https://github.com/Tuee22/infernix),
  [`jitML`](https://github.com/Tuee22/jitML)) so docs read the same across the family.

## Metadata Block

Every governed Markdown document under `documents/` starts with this block:

```markdown
# Title

**Status**: Authoritative source | Supporting reference | Draft
**Supersedes**: N/A | relative/path/to/old.md
**Referenced by**: [name](relative/link.md), [other](relative/other.md)

> **Purpose**: One-sentence summary.
```

Rules:

- the `# Title` line is the first non-empty line in the file
- `**Status**:` is required
- `**Supersedes**:` is required; use `N/A` when nothing is superseded
- `**Referenced by**:` is required, even when there is only one cross-reference
- the purpose blockquote is required
- YAML front-matter is no longer used; the metadata block replaces it

## Broad Doctrine Structure

Broad governed docs that define repository doctrine use stronger structure than a short reference
page.

Rules:

- include `## TL;DR` or `## Executive Summary` when the topic is broad
- include `## Current Status` when implemented behavior and target direction appear in the same
  document
- include `## Validation` when a gate (the code-check, the test runner, or a doc validator) proves
  the contract
- use explicit tables or matrices when ownership, substrate behavior, or a model summary is part of
  the contract
- answer these questions directly when relevant: what is the rule, what is current versus target,
  how is it validated, and what is `hostbootstrap`-internal detail versus a consumer-facing contract

## Governed Root Documents

The governed root documents use a parallel metadata block so readers and automation can distinguish
orientation or entry guidance from canonical topic ownership.

```markdown
# Title

**Status**: Governed orientation document | Governed entry document
**Supersedes**: short statement describing the root-level duplication this file replaces, or N/A
**Canonical homes**: [documents/...](documents/...), [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md)

> **Purpose**: One-sentence summary.
```

Rules:

- `README.md` uses `**Status**: Governed orientation document`
- `AGENTS.md` and `CLAUDE.md` use `**Status**: Governed entry document`
- every governed root doc carries both `**Supersedes**:` and `**Canonical homes**:` lines
- root docs summarize and link; they do not become parallel canonical homes for design or
  engineering topics

## Taxonomy

The canonical suite layout is:

```text
documents/
├── README.md
├── documentation_standards.md
├── architecture/
├── development/
├── engineering/
├── operations/
├── reference/
└── languages/
```

Rules:

- `documents/` is the only canonical documentation root
- `docs/` is not introduced
- `languages/` is a documented extra category that holds per-language toolchain guidance
  (`haskell.md`, `python.md`, `cuda.md`, …); it is reference material for what the base image ships
- new top-level categories require an update to this file and to `documents/README.md` in the same
  change that adds the directory

## Source Of Truth

- `DEVELOPMENT_PLAN/` owns phase order, current implementation status, and closure criteria.
- `documents/` owns architecture and engineering guidance once the relevant document exists.
- This file is canonical for `hostbootstrap`'s own `documents/` tree. Consuming projects keep their
  own documentation standards and link to this repository for the bootstrap layer.
- When current-state or closure claims in `documents/` conflict with `DEVELOPMENT_PLAN/`, reconcile
  the governed docs to `DEVELOPMENT_PLAN/`; do not use `documents/` as a parallel implementation
  status authority.
- `README.md` is a governed orientation layer and points to canonical documents instead of
  duplicating them.
- `AGENTS.md` and `CLAUDE.md` are governed entry documents and must stay aligned with the
  repository-level rules they summarize.

## Naming And Linking

- file names are lowercase `snake_case` with a `.md` suffix
- `README.md`, `AGENTS.md`, `CLAUDE.md`, and `LICENSE` are the only permitted ALL-CAPS file names
- avoid dates, version numbers, and project names in filenames — they rot; describe the topic
- relative Markdown links are required for in-repo references; references to consuming repositories
  use absolute URLs
- each governed doc links to at least one other governed source
- module names, commands, paths, types, and binaries use backticks

## Content Rules

- write current-state declarative guidance, not migration diaries
- keep one canonical home per topic
- move implementation status discussion into `DEVELOPMENT_PLAN/`
- describe `hostbootstrap` as the reusable host-management layer: a Haskell `hostbootstrap-core`
  library plus a thin Python bootstrapper, consumed by project binaries that extend the core
- the supported configuration substrate is typed Dhall; no governed doc may present shell-inherited
  environment values as a supported configuration source, except the documented invocation-context
  seam between the Python bootstrapper and the project binary
- when a rule is non-obvious, a tight WRONG/RIGHT example pair is encouraged, but a WRONG example
  must always be paired with the reason it is wrong

## Brevity

If a governed document grows past roughly 300 lines, ask whether it should split. Two focused
documents are easier to skim than one combined one.

## Update Rules

- when the `hostbootstrap-core` library surface (host-tool resolution, `ensure` reconcilers,
  substrate detection, cluster-lifecycle semantics, the command tree projects extend) changes,
  update the relevant `documents/architecture/*.md` and `documents/engineering/*.md` files and the
  affected phase document in the same change
- when the skeletal `hostbootstrap.dhall` schema changes, update
  `documents/engineering/schema.md` and the affected phase document in the same change
- when the base image contents or warm store change, update `documents/engineering/base_image.md`,
  `documents/engineering/warm_store.md`, and the affected phase document in the same change
- when the Python-bootstrapper / Haskell-core ownership boundary changes, update
  `documents/architecture/python_haskell_boundary.md` and the affected phase document
- when repository-level workflow rules change, review `README.md`, `AGENTS.md`, and `CLAUDE.md` in
  the same change

## Validation

The mechanical documentation validator is the `HostBootstrap.DocValidator` module in
`hostbootstrap-core`, exercised by the `hostbootstrap-core-test` suite (`DocValidatorSpec`) so it
runs through the project's canonical code-check. It verifies:

- required metadata lines for governed `documents/` content
- required structure for the broad doctrine docs (the `documents/architecture/` suite carries a
  `## TL;DR` or `## Executive Summary`)
- governed root-document metadata lines (`Status`, `Supersedes`, `Canonical homes`, purpose)
- relative link resolution for governed docs, governed root docs, and phase-plan docs
- root `README.md` references to both `documents/` and `DEVELOPMENT_PLAN/`
- `DEVELOPMENT_PLAN/` phase documents retaining their `## Documentation Requirements` section

Running `cabal test` (the canonical Haskell code-check) fails when any governed document drifts from
the rules above.
