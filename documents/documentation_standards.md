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
**Supersedes**: N/A | relative/path/to/old.md
**Referenced by**: [name](relative/link.md), [other](relative/other.md)

> **Purpose**: One-sentence summary.
```

Rules:

- the `# Title` line is the first non-empty line in the file
- `**Status**:` is required
- `**Supersedes**:` is required; use `N/A` when nothing is superseded
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

- file names are lowercase `snake_case` with a `.md` suffix
- `README.md`, `AGENTS.md`, `CLAUDE.md`, and `LICENSE` are the only permitted ALL-CAPS file names
- avoid dates, version numbers, and project names in filenames — they rot; describe the topic
- relative Markdown links are required for in-repo references; references to consuming repositories
  use absolute URLs
- each governed doc links to at least one other governed source
- module names, commands, paths, types, and binaries use backticks

## Content Rules

- state implemented behavior and target contracts declaratively, and label the boundary between them;
  keep implementation chronology out of governed topic documents
- keep one canonical home per topic
- keep mutable phase/sprint status, dependency order, closure criteria, and dated implementation
  evidence in `DEVELOPMENT_PLAN/`; a topic document may summarize the current defect only as needed to
  prevent its target contract from being mistaken for implemented behavior
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
`hostbootstrap-core`, exercised by the `hostbootstrap-core-test` suite (`DocValidatorSpec`) so it
runs through the project's canonical code-check. It verifies:

- required metadata lines for governed `documents/` content
- required structure for the broad doctrine docs (the `documents/architecture/` suite carries a
  `## TL;DR` or `## Executive Summary`)
- governed root-document metadata lines (`Status`, `Supersedes`, `Canonical homes`, purpose)
- relative link resolution for governed docs, governed root docs, and phase-plan docs; external URLs,
  pure anchors, and placeholder-shaped targets are intentionally skipped
- root `README.md` references to both `documents/` and `DEVELOPMENT_PLAN/`
- `DEVELOPMENT_PLAN/` phase documents retaining their `## Documentation Requirements` section
- lowercase `snake_case` file naming under `documents/` (only `README.md` is exempt)
- the canonical `documents/` taxonomy: every top-level category is one of
  `architecture`, `engineering`, `operations`, `languages` (the declared
  `allowedTaxonomy` set)

It additionally enforces the plan doctrine that
[development_plan_standards.md](../DEVELOPMENT_PLAN/development_plan_standards.md) states, because a
doctrine nothing checks is a preference:

- § A and § E: the `phase-NN-*.md` set is contiguous from 0; a phase's `Depends on` names only strictly
  lower-numbered phases; no phase title announces a reversal; and no `Remaining Work` section — phase-level
  or sprint-level — cites a higher-numbered phase. That last one is where the ordering rule is actually
  broken: "this closes when a later phase lands", written in prose, is a claim the `Depends on` field never
  sees. A forward link in `## Phase Objective` or `#### Validation` says who owns what and stays legal.
- § C and § G: every phase carries its header fields and a `## Documentation Requirements` section; each
  phase's status matches its `DEVELOPMENT_PLAN/README.md` row; every sprint declares a status from the
  closed vocabulary and carries no `Blocked by`; an `Active` phase and an `Active` sprint each carry a
  non-empty `Remaining Work`; and a `Done` sprint's begins "None".
- § I: every legacy-ledger row names exactly one deleting phase, read from its `Deleted by` cell, and that
  phase resolves.
- § II: no phase declares more than one non-baseline substrate.
- The contracts' own rule: every lettered section beneath `## hostbootstrap-Specific Contracts` opens with
  an `**Owning phase**:` line linking one phase document.

The validator checks that `**Referenced by**:` exists and that its links resolve. It deliberately does
not enforce literal backlink reciprocity: this field is curated conceptual-consumer metadata, not a
complete graph. Remove an entry when the named document no longer consumes the contract conceptually;
do not manufacture a reciprocal prose link solely to satisfy metadata.

The individual checks (`checkGovernedMeta`, `checkRootDoc`, `checkBroadDoctrine`,
`checkDocRequirements`, `checkLinks`, `checkReadmeRefs`, `checkNaming`, `checkTaxonomy`) are exported
from `HostBootstrap.DocValidator` so the same mechanical floor can be reused across the project
family. The plan-doctrine checks (`checkPhaseNumbering`, `checkPhaseHeader`, `checkPhaseStatusHarmony`,
`checkPhaseOrdering`, `checkRemainingWorkOrdering`, `checkNoReversal`, `checkSprintStructure`,
`checkActivePhaseRemainingWork`, `checkActivePhaseOwnsRemainingWork`, `checkDoneSprintRemainingWork`,
`checkDonePhaseRemainingWork`,
`checkSubstrateBudget`, `checkAcceptanceTerminal`, `checkLegacyLedger`, `checkContractOwnership`) are
exported alongside them.

`checkDonePhaseRemainingWork` is the newest and exists because of a gap the others left open. Its three
neighbours cover a sprint that is `Done`, a phase that is `Active`, and a sprint's owner; the one
combination nothing read was a *phase-level* `## Remaining Work` against the phase's own `**Status**`,
and that is the combination that occurred — a phase sat `Done`, with a current gate-evidence row, above a
section still declaring its live half owed. A check family is only as good as its least-covered corner,
so the rule is stated in the same shape as its sprint counterpart: the section must begin with `None`.

Three further checks relate a document to the tree rather than to another document, which is the
distinction that decides whether a green validator means anything: `checkImplementationPaths` resolves
every path a sprint cites, `checkArchitectureDrift` refuses a shape the architecture removed, and
`checkGateEvidence` recomputes the digest a phase's gate evidence claims to cover. The first two answer
"does this name still exist"; the third answers "has the source this run measured changed since", which
is the question a status field cannot answer about itself.

Each has a negative fixture proving it fires. The two scoped checks also assert an **absence** — a
forward link in a `#### Validation` section, and a bare phase citation inside a contract, must produce no
violation — because a check that flags everything is not a check that means anything.

From `core/`, `cabal test all` exercises the validator through the Haskell test suites and fails when a
governed document drifts from the rules above. That command is the test leg, not the complete Haskell
quality gate: the canonical code-check also runs the formatter check, linter, and a warnings-as-errors
build.

### Rules the validator grows to enforce

Each rule below is normative now and mechanical when its check lands. The
[documentation reconciliation phase](../DEVELOPMENT_PLAN/phase-29-documentation-reconciliation.md) owns
the implementations, one check per sprint, each with the negative fixture this section already requires.

- **A backticked identifier in governed prose names something that exists.** A module, type, function,
  constructor or CLI flag written in backticks resolves against the tree. This is the rule with the
  widest reach: a canonical contract page can otherwise describe a vocabulary the compiler has never
  seen, and every other check here will pass while it does. Prose that names a type abstractly is
  legitimate — [the plan standard](../DEVELOPMENT_PLAN/development_plan_standards.md) says so about its
  own shortened names — so the check carries an explicit reviewed allowlist rather than a silent skip.
- **A root document does not contradict the plan's status table.** `README.md`, `AGENTS.md` and
  `CLAUDE.md` may summarize status and must not restate it; where they do make a claim, it agrees with
  [the plan index](../DEVELOPMENT_PLAN/README.md).
- **`AGENTS.md` and `CLAUDE.md` agree.** The two are one document with two audiences. They differ only
  in the words naming that audience.
- **A relative link resolves including its anchor.** A `#section-name` fragment names a heading the
  target actually has.
- **A phase header carries no field § G does not declare.** An undeclared field is a convention one
  phase invented and the others do not share.
- **The architecture-drift guard reads the test tree as well as the source tree.** A rule about how
  source may cite a phase applies to the suites too, or it is a rule about where the check looks.

### Prior extensions

The reconciliation phase also carries architecture absence guards and phase-name citation checks over
governed documents and production source. Each architecture refusal names the constructive phase to
rewrite and its rationale; negative fixtures prove the checks detect removed authority modules and
unrestricted service handlers.
