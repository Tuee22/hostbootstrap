# Documentation Standards

**Status**: Authoritative source
**Supersedes**: prior YAML-front-matter documentation convention for this repository
**Referenced by**: [README.md](README.md), [../CLAUDE.md](../CLAUDE.md), [../AGENTS.md](../AGENTS.md)

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
**Supersedes**: N/A | relative/path/to/old.md | short statement of the description this page replaces
**Referenced by**: [name](relative/link.md), [other](relative/other.md)

> **Purpose**: One-sentence summary.
```

Rules:

- the `# Title` line is the first non-empty line in the file
- `**Status**:` is required
- `**Supersedes**:` is required; use `N/A` when nothing is superseded, a relative path when a file is,
  and a short statement when the page replaces a description that had no file of its own
- `**Referenced by**:` is required, even when there is only one cross-reference
- `**Referenced by**:` is a curated, non-exhaustive ownership/navigation list of documents that
  conceptually consume the page's contract; it is not a mechanically reciprocal graph, and a listed
  consumer need not contain a literal return link
- the purpose blockquote is required
- Document metadata uses the metadata block, not YAML front-matter

## Broad Doctrine Structure

Broad governed docs that define repository doctrine use stronger structure than a short reference
page.

Rules:

- include `## TL;DR` or `## Executive Summary` when the topic is broad; this is a recommended
  convention everywhere, but the mechanical validator only gates it for `documents/architecture/`
  docs (see `## Validation`) — elsewhere it is convention, not an enforced requirement
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
├── engineering/
├── operations/
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

- under `documents/`, file names are lowercase `snake_case` with a `.md` suffix, and `README.md` is the
  one exception
- at the repository root, `README.md`, `AGENTS.md`, `CLAUDE.md`, and `LICENSE` are the only ALL-CAPS
  file names
- these naming rules do not govern other trees: `DEVELOPMENT_PLAN/` phase documents follow the plan standard's
  `phase-NN-name.md` form, and source files follow their language's conventions
- avoid dates and version numbers in `documents/` file names — they rot; name the topic, which may be
  a component of this repository
- relative Markdown links are required for in-repo references; references to consuming repositories
  use absolute URLs
- each governed doc links to at least one other governed source
- module names, commands, paths, types, and binaries use backticks

## Content Rules

- state implemented behavior and target contracts declaratively, and label the boundary between them;
  keep implementation chronology out of governed topic documents
- keep one canonical home per topic
- *substrate*, *frame*, and *cordon* are defined once, in the
  [documents index](README.md#glossary). A page using one of them in a narrower sense says which sense
  it means rather than redefining the term; for *frame*, the glossary names three senses (topology,
  host frame, frame table), and an unqualified "frame" means the topology sense
- keep mutable phase/sprint status, dependency order, closure criteria, and dated implementation
  evidence in `DEVELOPMENT_PLAN/`; a topic document may summarize the current defect only as needed to
  prevent its target contract from being mistaken for implemented behavior
- outside `DEVELOPMENT_PLAN/`, cite a phase by its name and a link to its phase document, never by a
  bare number, and do not cite sprints
  ([§ J](../DEVELOPMENT_PLAN/development_plan_standards.md#j-readme-and-documents-harmony)). The rule
  covers comments and strings in the source and test trees as well as `documents/`, and
  `checkArchitectureDrift` refuses the word "phase" or "sprint" followed by a space and a digit there
  (see [Validation](#validation))
- describe `hostbootstrap` as the reusable host-management layer: a Haskell `hostbootstrap-core`
  library plus a thin Python bootstrapper, consumed by project binaries that extend the core
- the supported configuration format is typed Dhall; no governed doc may present shell-inherited
  environment values as a supported configuration source. The one environment input the Python
  bootstrapper sets on the project binary is the host statement — the detected substrate and
  architecture pair — which is a statement about the host, not configuration; its canonical home is
  [who detects the host](architecture/python_haskell_boundary.md#who-detects-the-host)
- when a rule is non-obvious, a tight WRONG/RIGHT example pair is encouraged, but a WRONG example
  must always be paired with the reason it is wrong
- link the owning module as the signature reference and describe its contract; do not maintain a
  second set of illustrative Haskell signatures beside it. A sketch is unchecked by the compiler, so
  it drifts silently, and a reader designing against a drifted sketch designs against nothing. Named
  types, constructors and functions in backticks, a table of the cases a closed kind admits, and a
  link to the module are the supported way to describe an API; a fenced `haskell` block restating its
  declarations is not. The validator does not yet enforce this rule (see [Current Status](#current-status))

## Brevity

If a governed document grows past roughly 300 lines, ask whether it should split. Two focused
documents are easier to skim than one combined one.

This one is **advisory and deliberately unchecked**. Several governed documents are legitimately longer
than the guideline because their subject is a single contract that does not decompose, and a mechanical
limit would report those every run — a check that flags what it cannot fix trains a reader to ignore
it. Ask the question; do not expect the validator to ask it for you.

## Update Rules

- when the `hostbootstrap-core` library surface (host-tool resolution, `ensure` reconcilers,
  substrate detection, cluster-lifecycle semantics, the command tree projects extend) changes,
  update the relevant `documents/architecture/*.md` and `documents/engineering/*.md` files and the
  affected phase document in the same change
- when the project-local `<project>.dhall` schema changes, update `documents/engineering/schema.md` and
  the affected phase document in the same change
- when the base image contents or warm store change, update `documents/engineering/base_image.md`,
  `documents/engineering/warm_store.md`, and the affected phase document in the same change
- when the Python-bootstrapper / Haskell-core ownership boundary changes, update
  `documents/architecture/python_haskell_boundary.md` and the affected phase document
- when repository-level workflow rules change, review `README.md`, `AGENTS.md`, and `CLAUDE.md` in
  the same change

## Validation

The mechanical documentation validator is the `HostBootstrap.DocValidator` module in
`hostbootstrap-core`. Its entry point `validateRepo` takes a repository root and returns every
`Violation` it finds — a repository-relative file and a one-line message, which `renderViolation`
prints — sorted by file. `findRepoRoot` locates that root by walking up from a directory to the first
one that holds both `documents/` and `DEVELOPMENT_PLAN/`. Every check below is exported with the same
root-first argument shape, so a project in the family reuses the floor by calling `validateRepo` on its
own root or by composing the individual checks.

`DocValidatorSpec`, in the `hostbootstrap-core-test` suite, runs `validateRepo` over this repository and
fails on any violation. The validator therefore runs wherever `cabal test all` runs from `core/`: the
first leg of the host static gate
([§ JJ](../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness)),
and one of the repository quality gates that `hostbootstrap base build` and
`hostbootstrap base build-and-push` complete before any image is built.
`poetry run python -m hostbootstrap.check_code` does not run it. `cabal test all` is the test leg, not
the whole Haskell quality gate: [code-check doctrine](engineering/code_check_doctrine.md) is the
canonical home of where the formatter and linter run, and every `cabal build` already holds `-Werror`
through each package's `common warnings` stanza.

### Checks over governed documents

| Check | Rule | What it reads |
|---|---|---|
| `checkGovernedMeta` | The first non-empty line is a `# Title`; the `**Status**:`, `**Supersedes**:` and `**Referenced by**:` lines and the `> **Purpose**:` blockquote are present; there is no YAML front-matter. It checks presence only: the Status value and the Supersedes form are not read. | every Markdown file under `documents/` |
| `checkBroadDoctrine` | A `## TL;DR` or `## Executive Summary` heading is present. | `documents/architecture/` only |
| `checkNaming` | The file name is lowercase `snake_case` with a `.md` suffix; `README.md` is exempt. | `documents/` |
| `checkTaxonomy` | Every directory directly under `documents/` is one of `allowedTaxonomy`: `architecture`, `engineering`, `operations`, `languages`. | `documents/` |
| `checkRootDoc` | The document exists; its first non-empty line is a `# Title`; its `**Status**:` line reads `Governed orientation document` (`README.md`) or `Governed entry document` (`AGENTS.md`, `CLAUDE.md`); the `**Supersedes**:` and `**Canonical homes**:` lines and the purpose blockquote are present. | the three root documents |
| `checkReadmeRefs` | The root `README.md` mentions both `documents/` and `DEVELOPMENT_PLAN/`. | root `README.md` |
| `checkLinks` | Every relative link target resolves to a file or a directory. Skipped: links inside fenced blocks; external targets (`http://`, `https://`, `mailto:`); pure `#fragment` links; root-absolute targets starting with `/`; and targets containing `...`, `<`, `>` or a space. | `documents/`, every Markdown file under `DEVELOPMENT_PLAN/`, and the root documents |
| `checkLinkAnchors` | A cross-document link's `#fragment` names a heading of its `.md` target, under `headingSlug`. A same-page `#fragment` link is not checked, and a link to a missing or non-Markdown target is left to `checkLinks`. | the same files as `checkLinks` |
| `checkIdentifierResolution` | The leading token of each inline code span, when it is shaped `CapWords`, `camelCase` or dotted, appears as a word of the source corpus, or (dotted) as a module name or with its last component a word, or is in `identifierAllowlist`. | inline code spans outside fenced blocks, in `documents/` only |
| `checkRootDocStatus` | A line that both references a phase by number (a `phase-NN-` link, or "Phase" followed by the number) and names `Done`, `Active` or `Planned` agrees with that phase's row in [the plan index](../DEVELOPMENT_PLAN/README.md). A status claim with no numbered reference is not seen. | the three root documents |
| `checkEntryDocAgreement` | `AGENTS.md` and `CLAUDE.md` have the same number of lines, and each `CLAUDE.md` line equals its `AGENTS.md` line after the declared `audienceMapping` replacements. | `AGENTS.md`, `CLAUDE.md` |
| `checkArchitectureDrift` | Two rules. The modules the architecture removed do not exist, and the forbidden boundary names do not appear in the modules that once carried them; each refusal names the phase document to rewrite and its rationale anchor. And no line carries the word "phase" or "sprint" followed by a space and a digit. | the named source modules; then `documents/` and every `.hs` and `.py` file under `driftSourceRoots` — `src`, `internal`, `app`, `test` and `provider-live` of `hostbootstrap-core`, the demo's `src`, `app` and `test`, `hostbootstrap/` and `tests/` — except `DocValidatorSpec.hs`, the one name in `driftCitationExemptions` |

`checkIdentifierResolution` answers a narrower question than "does this name exist". Its corpus is every
word, comments and string literals included, of the `.hs`, `.py`, `.dhall`, `.purs` and `.cabal` files
under `corpusRoots`: the source, internal, app, test, provider-live and Dhall trees of
`hostbootstrap-core`, the demo's source, app, test and web-source trees, `hostbootstrap/`, and `tests/`.
A resolved name is one somebody has written somewhere in those trees; it is not proved declared or
exported, so a name the validator's own forbidden lists spell resolves. A span that starts with `--`, or
whose leading token is lowercase, `snake_case` or kebab-case, is not a candidate, so command-line flags
and lowercase function names are not resolved. What it cannot resolve is compared against
`identifierAllowlist` — reviewed, grouped by reason, and deliberately small — rather than skipped.

### Checks over the development plan

These hold the doctrine that
[development_plan_standards.md](../DEVELOPMENT_PLAN/development_plan_standards.md) states, because a
doctrine nothing checks is a preference. Each reads the `phase-NN-*.md` documents unless the table says
otherwise.

| Check | Rule (plan section) |
|---|---|
| `checkDocRequirements` | Every phase document has a `## Documentation Requirements` section (§ C). |
| `checkPhaseNumbering` | The phase documents are numbered contiguously from 0, with no duplicate (§ E). |
| `checkPhaseHeader` | The `**Status**`, `**Depends on**`, `**Substrates**`, `**Gate**` and `**Gate kind**` header fields are present; the status is `Done`, `Active` or `Planned`; the gate kind is `self-verifying` or `deferred` (§ G). |
| `checkPhaseHeaderFields` | The header carries no field outside the declared set: those five plus `**Gate evidence**` and `**Evidence covers**` (§ G). |
| `checkPhaseStatusHarmony` | The status table in `DEVELOPMENT_PLAN/README.md` has exactly one well-formed row per phase, joined on number and link, and each row's status equals that phase's header (§ J). |
| `checkPhaseOrdering` | `**Depends on**` names only strictly lower-numbered phases (§ A). |
| `checkAcceptanceTerminal` | No phase depends on a phase whose `**Substrates**` is `apple-silicon`, `nvidia` or `windows` (§ II). |
| `checkRemainingWorkOrdering` | No phase-level `## Remaining Work` or sprint-level `#### Remaining Work` links a higher-numbered phase document. A forward link in `## Phase Objective` or `#### Validation` says who owns what and stays legal (§ A). |
| `checkNoReversal` | No phase or sprint title carries a reversal word such as `Superseded`, `Historical` or `Retired` (§ A). |
| `checkSprintStructure` | Every sprint title carries a `Done`, `Active` or `Planned` tag that equals its `**Status**` field; no sprint carries `**Blocked by**`; an `Active` sprint's `#### Remaining Work` is not empty (§ C, § G). |
| `checkDoneSprintRemainingWork` | A `Done` sprint has a `#### Remaining Work` that begins with `None` (§ C, § G). |
| `checkDonePhaseRemainingWork` | A `Done` phase's `## Remaining Work` begins with `None`, the same shape as the sprint rule (§ C). |
| `checkActivePhaseRemainingWork` | An `Active` phase has a non-empty section headed exactly `## Remaining Work` (§ C). |
| `checkActivePhaseOwnsRemainingWork` | An `Active` phase's `## Remaining Work` names at least one sprint, every sprint it names is defined in the phase, and at least one of them is `Active` (§ C). |
| `checkSubstrateBudget` | Every `**Substrates**` value is one of `none`, `none (static)`, `linux-cpu`, `apple-silicon`, `nvidia`, `windows`, and no phase declares more than one non-baseline substrate (§ II). |
| `checkImplementationPaths` | Every path a sprint's `**Implementation**` field cites exists from the repository root; a globbed citation is a scope and is not resolved (§ D). |
| `checkGateEvidence` | A `Done` phase records at least one `**Gate evidence**` row, and every row has the form date ; host ; backticked command ; `pass` ; covers value. A self-verifying phase covers `in-gate`; a deferred phase covers a SHA-256 digest, names `**Evidence covers**` paths, and the digest measured over those paths today equals the recorded one (§ II). A covers path that is missing, unlistable, or contributes no files is refused. |
| `checkGateEvidenceLegs` | When a phase records evidence, every command leg its `**Gate**` names appears in some evidence row, compared on non-flag tokens as a subsequence. A leg is one `&&`-separated part of a backticked span whose first word is `cabal`, `poetry`, `hostbootstrap`, `python`, `python3` or `docker` (§ G). |
| `checkLegacyLedger` | Each row of [the legacy ledger](../DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md) names exactly one deleting phase in its `Deleted by` cell, and that phase document exists (§ I). Reads the ledger. |
| `checkContractOwnership` | Every lettered section beneath `## hostbootstrap-Specific Contracts` carries an `**Owning phase**:` line linking one phase document. Reads the plan standard. |

`checkImplementationPaths`, `checkArchitectureDrift`, `checkIdentifierResolution` and `checkGateEvidence`
relate a document to the tree rather than to another document, which is what makes a green run mean
something: the first three ask whether a name is still there, and the last asks whether the source a run
measured has changed since — the question a status field cannot answer about itself.

The validator checks that `**Referenced by**:` exists and that its links resolve. It deliberately does
not enforce literal backlink reciprocity: this field is curated conceptual-consumer metadata, not a
complete graph. Remove an entry when the named document no longer consumes the contract conceptually;
do not manufacture a reciprocal prose link solely to satisfy metadata.

### Negative fixtures

`DocValidatorSpec` also builds miniature repositories in temporary directories and asserts that each
broken shape produces its violation, so a check that silently stops firing fails the suite. Every check
in the two tables has such a fixture except those [Current Status](#current-status) lists. The following
fixtures also assert an **absence**, because a check that flags everything means nothing:

- `checkLinks`: a link inside a fenced example produces no unresolved-link violation.
- `checkRemainingWorkOrdering`: a sprint's `#### Validation` that links a higher-numbered phase produces
  no violation; only the two `Remaining Work` citations are reported.
- `checkContractOwnership`: a core principle with no owner, and a contract that declares its
  `**Owning phase**:` line, produce no violation, while a contract that only mentions a phase is still
  reported. Citing a phase inside a contract does not stand in for the declared field.
- `checkLegacyLedger`: a phase cited in a row's reason column does not count toward that row's deleting
  phases.

### Rules held by review

These rules of this standard are not read by any check. A green validator says nothing about them.

| Rule | Why no check reads it |
|---|---|
| The `**Status**:` value is one of the metadata-block values, and `**Supersedes**:` takes one of its three forms | `checkGovernedMeta` reads presence only |
| A broad page outside `documents/architecture/` carries a summary section | convention there; `checkBroadDoctrine` reads only `documents/architecture/` |
| A page mixing current and target behaviour carries `## Current Status`; a gated contract carries `## Validation` | needs a judgement about the page's content |
| Each governed page links at least one other governed source | not implemented; reviewed |
| `**Referenced by**:` is reciprocal | deliberately not a rule (above) |
| One canonical home per topic, declarative present tense, no chronology, a narrower sense of a glossary term is declared | needs a judgement about the prose |
| A page past roughly 300 lines asks whether it should split | advisory ([Brevity](#brevity)) |
| No fenced `haskell` block restates declarations | owed (see [Current Status](#current-status)) |

## Current Status

The checks in the two tables above are implemented and run in every `cabal test all` from `core/`. The
following parts of the documentation and plan doctrine are stated but not yet checked, and the
[documentation reconciliation phase](../DEVELOPMENT_PLAN/phase-25-documentation-reconciliation.md) owes
each of them:

- **identifier resolution beyond `documents/`, against declarations.** `checkIdentifierResolution` reads
  only `documents/`, so a backticked name in `DEVELOPMENT_PLAN/` or a root document is never resolved,
  and it resolves against a word corpus rather than against the exact declarations of the tree;
- **resolution of cited test cases.** No check confirms that a spec or test case a sprint's
  `#### Validation` cites exists in the suites;
- **gate legs for every declared command.** `checkGateEvidenceLegs` compares only legs whose first word
  is one of its six recognized commands, so a leg run through any other command — a project binary, for
  example — is not compared against the evidence row;
- **the fenced-`haskell` ban** in [Content Rules](#content-rules), which no check enforces;
- **anchor resolution at its full reach.** `checkLinkAnchors` does not check a same-page `#fragment`,
  counts a `#`-prefixed line inside a fenced block as a heading, drops underscores from a slug where
  the GitHub renderer keeps them, and gives a repeated heading no `-1`, `-2` suffix;
- **the plan-doctrine checks without gaps.** `checkSprintStructure` passes an `Active` sprint that has no
  `#### Remaining Work` section at all, and a sprint whose body has no `**Status**` field, so its title
  tag is its only status. The phase header block ends only at a literal `## ` line, so a phase with no
  header `**Status**` can take its first sprint's. `checkGateEvidence` takes its evidence rows and
  `**Evidence covers**` from anywhere in the document rather than from the header block.
  `checkRemainingWorkOrdering` reads only links, so a later phase cited in prose inside a Remaining Work
  section passes. `checkContractOwnership` passes a plan standard whose contracts heading is renamed or
  holds no lettered section. `checkLegacyLedger` skips a row with too few cells. `checkSubstrateBudget` refuses a
  comma-separated declaration such as `linux-cpu, nvidia` that the plan standard permits;
- **one verdict on every host.** Path resolution in `checkLinks`, `checkLinkAnchors`,
  `checkImplementationPaths` and the ledger check inherits the host filesystem's case rule, so a link
  whose case differs from the file passes on a case-insensitive host. Files are decoded under the
  process locale and its native newline mode rather than as strict UTF-8 with any trailing carriage
  return stripped, and `checkReadmeRefs` reads lazily. `checkRootDocStatus` pairs every phase a line
  references with every status word on it, so a line naming two phases can report a false disagreement;
- **negative fixtures for the deferred-evidence rules** of `checkGateEvidence`: an `in-gate` row on a
  deferred phase, a digest row on a self-verifying one, a deferred `Done` phase naming no
  `**Evidence covers**` paths; and likewise fixtures for
  `checkDonePhaseRemainingWork`, `checkActivePhaseOwnsRemainingWork`, and the drift guard's reading of
  the test roots, whose fixture writes numeric citations only under `documents/` and the source tree.
