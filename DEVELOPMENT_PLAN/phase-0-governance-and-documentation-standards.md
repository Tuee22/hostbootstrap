# Phase 0 — Governance and documentation standards

**Status**: Active
**Depends on**: nothing
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

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

`DocValidatorSpec` runs `checkGovernedMeta` over every Markdown file under `documents/` in the live
repository. The check reads presence, not order: the first non-empty line is a `# Title`, the
`**Status**:`, `**Supersedes**:` and `**Referenced by**:` lines and the `> **Purpose**:` blockquote each
appear somewhere in the file, and the file does not open with a `---` YAML fence. The stated order of the
block is a property of the governed documents themselves, which `documents/documentation_standards.md`
records as outside the check's scope.

#### Remaining Work

None. The YAML front-matter refusal's negative fixture is Sprint 0.3's.

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
- § K–§ NN state the normative technical contracts once, in final form.

#### Validation

The tree is contiguous from `phase-0` with no gaps, and every relative link resolves.

#### Remaining Work

None.

### Sprint 0.3: The documentation validator [Active]

**Status**: Active
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
  phase title or sprint title carries reversal vocabulary (`checkNoReversal` scans only `# Phase ` and
  `### Sprint ` heading lines, because body prose legitimately says "release removes the directory");
  sprint structure and the closed status vocabulary hold; a phase declares at most one non-baseline
  substrate; each phase's status matches its README row; the phase set is contiguous. The doctrine that
  lives in prose rather than in a field is Sprint 0.4's.
- A negative fixture proves every check is non-vacuous: each refusal fires on a miniature repository built
  to trip it, and the fenced-code exemption is proved by an asserted absence.

#### Validation

`DocValidatorSpec` runs `validateRepo` against the live repository and fails on any violation, then runs
the negative fixture. Both execute inside the canonical `cabal test all --ghc-options=-Werror` from
`core/`. The sprint closes when `negativeCase` in `core/hostbootstrap-core/test/DocValidatorSpec.hs`
also asserts that the YAML front-matter refusal fires and that a link inside a fenced code block produces
no violation, as listed under Remaining Work, and that gate passes.

Dated evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), the focused `DocValidatorSpec` passed 2/2,
and the exact phase gate, `cabal test all --ghc-options=-Werror` from `core/`, passed 1426/1426 cases in
67.48 seconds. The negative fixture exercised missing, malformed, duplicate, unmatched, and mismatched
phase-status rows.

#### Remaining Work

- `negativeCase` in `core/hostbootstrap-core/test/DocValidatorSpec.hs` writes a governed document
  `documents/architecture/yaml_header.md` whose first non-empty line is `---` followed by a `title:` line
  and a closing `---`, then the full metadata block, and adds `"YAML front-matter"` to the expected
  violation list, so the `hasYamlFrontMatter` branch of `checkGovernedMeta` is proved to fire.
- The same fixture writes a well-formed governed document whose body holds a fenced code block
  containing a Markdown link to the absent file `fenced_target_missing.md`, and asserts that no rendered
  violation mentions `fenced_target_missing.md`, so `stripFencedCode` is proved to exempt fenced examples from the link check
  rather than the exemption being inferred from the live tree passing.

### Sprint 0.4: The doctrine checks a green build can hide [Active]

**Status**: Active
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
- `checkLegacyLedger` carries an arity clause reading the row's `Deleted by` cell alone — the cell between
  the row's last two pipes, read even when it is blank — so a phase cited in the `Why` column neither
  satisfies nor inflates it, and a row with an empty `Deleted by` cell is reported as naming no deleting
  phase. Two owners is the same failure as none: neither phase's completion empties the row (§ I).
- `checkContractOwnership`: every contract beneath `## hostbootstrap-Specific Contracts` opens with an
  `**Owning phase**:` line. Inferring an owner from any phase a section happens to cite is not the same
  claim — § O mentions ten phases and is owned by one.
- Each guard's negative fixture proves it fires, and the two scoped guards additionally assert an
  **absence** — a forward link in a `#### Validation` section and a bare citation inside a contract must
  produce no violation — so the scoping is proved rather than assumed.

#### Validation

`DocValidatorSpec` against the live repository and against the negative fixture, inside
`cabal test all --ghc-options=-Werror` from `core/`. `negativeCase` proves each guard fires: Sprint 11.1's
and the phase's `Remaining Work` citing phase 12, a missing `## Remaining Work` and the drifted
`## Phase Remaining Work` heading on an Active phase, a Done sprint declaring work and one with no
section, an unowned, an unresolvable, and a two-owner ledger row, and contract section N naming no owning
phase. It proves the scopings by absence: exactly two `cites phase 12` violations (the forward link in
Sprint 11.2's `#### Validation` is legal), no violation for contract sections A and K, and no
`names 3 deleting phases` for the row citing a phase in its `Why` column. The sprint closes when the
blank-`Deleted by` case under Remaining Work exists and passes in that gate.

Dated evidence: on 2026-08-18, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,951/1,951 in 241.11 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

#### Remaining Work

- `deletingCell` in `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs` takes the last
  non-empty cell, so a tracked row whose `Deleted by` cell is blank reads its `Why` cell as the deleting
  cell. Rewrite it to split the row on `|`, drop the empty segment after the closing pipe, and return the
  final cell unfiltered (blank included), so `rowViolations` sees an empty `Deleted by` cell as naming no
  phase.
- Add to the ledger fixture in `negativeCase` (`core/hostbootstrap-core/test/DocValidatorSpec.hs`) a
  fourth tracked row whose `Shape` cell reads `a fourth`, whose `Location` cell reads `src/W.hs`, whose
  `Why` cell holds a Markdown link to the fixture phase document `phase-10-doctrine.md`, and whose
  `Deleted by` cell is blank. Assert that exactly two `legacy ledger row names no deleting phase`
  violations are reported (the `nobody in particular` row and this one), so a phase linked in the `Why`
  column cannot satisfy a blank `Deleted by` cell.

### Sprint 0.5: A covers digest refuses a path that contributes nothing [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Digest.hs`,
`core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`
**Substrates**: none
**Docs to update**: `documents/documentation_standards.md`

#### Objective

`measurePathSetDigest` is what every deferred phase's `**Evidence covers**` digest is measured with, and
its contract is that a cited path that cannot be read is a typed `DigestPathUnavailable` refusal naming
the path, never a digest over nothing and never an escaped exception. This sprint makes the directory
branch of `collect` hold that contract and proves every refusal and the drift comparison with fixtures.

#### Deliverables

- A directory named directly in the covers set that contributes no file — empty, or holding only
  `generatedNames` entries such as `__pycache__` — is refused as `DigestPathUnavailable "<path>: directory contributes no files"`, so a
  covers set whose source was deleted cannot keep a stable digest.
- `listDirectory` in the directory branch of `collect` runs under `try`; a listing failure (permission
  denied, or the directory removed between `doesDirectoryExist` and the listing) becomes
  `DigestPathUnavailable (path <> ": " <> firstLine (show err))`, the same shape `readBytes` produces, so
  `measurePathSetDigest` returns `Left` rather than throwing.
- The `generatedNames` filter and the forward-slash normalisation of framed paths are proved by tests.
- The `HostBootstrap.Digest` module header states what the module supplies — the lowercase-hex
  `sha256Hex`, the 8-byte big-endian length prefix `frameWire`, and `measurePathSetDigest`, which
  `DocValidator` measures `**Evidence covers**` sets with — and names `Build.measureSourceDigest` as the
  separate measurement of a build's source context.
- A known-answer case pins `sha256Hex` and `frameWire` to their published values, so every module that
  imports them hashes and frames against a fixed reference.

#### Validation

`DocValidatorSpec` gains a case, run inside `cabal test all --ghc-options=-Werror` from `core/`, that
builds a miniature repository and calls `measurePathSetDigest` (the test suite already depends on
`hostbootstrap-core:ownership-internal`) and `checkGateEvidence` on a `Done` phase document with
`**Gate kind**: deferred`. It asserts: a missing covers path yields `Left (DigestPathUnavailable _)` naming
the path, and `checkGateEvidence` reports `'**Evidence covers**' cannot be measured`; an empty directory
and a directory holding only `__pycache__/x.pyc` each yield that refusal; adding a file under
`__pycache__` beside real source leaves the digest unchanged; changing one byte of a covered source file
makes `checkGateEvidence` report `now measures` against the recorded digest, while the recorded digest
equal to the measured one produces no violation; and a covers set measured from a nested directory yields
the same digest whichever separator the cited path is written with. On a host where
`System.Directory.setPermissions` can revoke listing (POSIX), a covered subdirectory with read and search
permission removed yields the listing refusal rather than an exception. A second `DocValidatorSpec` case
asserts `sha256Hex ""` is `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
`sha256Hex "abc"` is `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`, and
`frameWire "ab"` is the seven zero bytes, `0x02`, then `ab`.

#### Remaining Work

- In `collect` (`core/hostbootstrap-core/internal/ownership/HostBootstrap/Digest.hs`), wrap
  `listDirectory` in `try` and map failure to `DigestPathUnavailable`, and return
  `Left (DigestPathUnavailable (path <> ": directory contributes no files"))` when the filtered, recursed
  listing of a cited top-level path concatenates to no entries.
- Add the miniature-repository digest case described under Validation to
  `core/hostbootstrap-core/test/DocValidatorSpec.hs`, importing `HostBootstrap.Digest`.
- Add the `sha256Hex` and `frameWire` known-answer case described under Validation to
  `core/hostbootstrap-core/test/DocValidatorSpec.hs`.
- Extend the `checkGateEvidence` row of `documents/documentation_standards.md`'s check table to state that
  a covers path that is missing, unlistable, or contributes no files is refused.
- Rewrite the module header of `core/hostbootstrap-core/internal/ownership/HostBootstrap/Digest.hs`. It
  calls the module "the one SHA-256 spelling", narrates the spellings that preceded it, and says
  `measurePathSetDigest` keeps every property "the build-authority measurement already had", while
  `Build.measureSourceDigest` is a separate measurement that does not call it and other modules define
  their own `sha256Hex`. The header states the three exports listed under Deliverables and their one
  in-tree measuring caller, `DocValidator`.

### Sprint 0.6: Every tracked text file has a declared line ending [Planned]

**Status**: Planned
**Implementation**: `.gitattributes`
**Substrates**: none
**Docs to update**: `CLAUDE.md`, `AGENTS.md`

#### Objective

`.gitattributes` is the authoritative line-ending policy: LF for all text, CRLF for Windows scripts, and
no dependence on a machine's `core.autocrlf`. The policy holds only where an attribute names an `eol`, so
the default rule names one too.

#### Deliverables

- The default rule reads `* text=auto eol=lf`, so a tracked text file no pattern lists (such as
  `.editorconfig`) checks out LF regardless of `core.autocrlf`, while the `*.bat`, `*.cmd` and `*.ps1`
  rules keep CRLF and the binary rules keep their files untouched.

#### Validation

`git ls-files --eol` reports `eol=lf` or `eol=crlf` in the attribute column for every tracked text file,
and its index column reports `i/lf` for every tracked text file other than a Windows script, so the change
carries no line-ending churn. The host static gate (§ JJ) passes afterwards.

#### Remaining Work

- Change line 5 of `.gitattributes` from `* text=auto` to `* text=auto eol=lf`, then confirm with
  `git ls-files --eol` that `.editorconfig` reports `attr/text=auto eol=lf` and that no tracked text file
  reports an attribute column without an `eol=` value.

## Remaining Work

- Sprint 0.3: negative fixtures for the YAML front-matter refusal and the fenced-code link exemption.
- Sprint 0.4: `deletingCell` reads a blank `Deleted by` cell as blank, with a fixture row proving a `Why`
  link cannot satisfy it.
- Sprint 0.5: `measurePathSetDigest` refuses an empty or unlistable covered directory, with digest
  refusal, generated-name, separator, and drift fixtures, known-answer vectors pin `sha256Hex` and
  `frameWire`, and its module header states its three exports and their measuring caller.
- Sprint 0.6: `.gitattributes` default rule names `eol=lf`.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/README.md` — the taxonomy index and canonical-home map.

**Engineering docs to create/update:**
- `documents/documentation_standards.md` — the metadata block, taxonomy, and validator contract.

**Cross-references to add:**
- `README.md`, `AGENTS.md`, and `CLAUDE.md` point at the canonical governance homes.
- `DEVELOPMENT_PLAN/README.md` and `00-overview.md` defer doctrine to
  [development_plan_standards.md](development_plan_standards.md).
