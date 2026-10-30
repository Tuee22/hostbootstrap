# Phase 0 — Governance and documentation standards

**Status**: Done
**Depends on**: nothing
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-10-26 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 10.0.26300.9457, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` from `core/` ; pass ; covers in-gate

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
  phase title or sprint title carries reversal vocabulary (`checkNoReversal` scans only `# Phase ` and
  `### Sprint ` heading lines, because body prose legitimately says "release removes the directory");
  sprint structure and the closed status vocabulary hold; a phase declares at most one non-baseline
  substrate; each phase's status matches its README row; the phase set is contiguous. The doctrine that
  lives in prose rather than in a field is Sprint 0.4's.
- A negative fixture proves every check is non-vacuous: each refusal fires on a miniature repository built
  to trip it, and the fenced-code exemption is proved by an asserted absence.

#### Validation

`DocValidatorSpec`'s `validator flags missing metadata, links, and sections` case
(`negativeCase`) asserts the YAML front-matter refusal even when the full metadata block follows it,
and asserts that no violation mentions `fenced_target_missing.md` from the fenced example. The
`governed documentation conforms to the standard` case validates the live repository.

On 2026-10-26, native x86_64 Windows 11 (`DESKTOP-R6BTBVS`), GHC 9.12.4 and Cabal 3.16.1.0,
plain `cabal test all` from `core/` passed all 2,550 core cases, including all 13 `DocValidatorSpec`
cases. The provider-live component reported its declared unrequested-lane `Unsupported`; no live
provider acceptance is claimed.

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

`DocValidatorSpec`'s `validator flags missing metadata, links, and sections` case
(`negativeCase`) proves the doctrine guards and their scoped absences. Its fourth ledger row links
phase 10 only in `Why` and leaves `Deleted by` blank. Exactly two rows report
`legacy ledger row names no deleting phase`, proving the blank cell cannot borrow that link.

On 2026-10-26, plain `cabal test all` from `core/` passed all 2,550 core cases on native x86_64
Windows 11 (`DESKTOP-R6BTBVS`), GHC 9.12.4 and Cabal 3.16.1.0.

#### Remaining Work

None.

### Sprint 0.5: A covers digest refuses a path that contributes nothing [Done]

**Status**: Done
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

`DocValidatorSpec`'s `covers digests refuse unavailable paths and detect source drift` case
(`digestCase`) checks missing, empty and generated-only cited paths as typed refusals and as
`checkGateEvidence` violations. Generated cache files and empty descendants leave a real source tree's
digest unchanged. Directory and file citations agree across forward-slash and backslash separators.
Matching evidence passes; changing one source byte reports the recorded and newly measured digests.
The permission probe compares the real kernel's listing result with the digest result and restores
permissions with `bracket`.

`SHA-256 and wire framing match known-answer vectors` (`digestVectorCase`) pins the empty and `abc`
SHA-256 digests and the eight-byte big-endian length prefix of `frameWire "ab"`.

On 2026-10-26, plain `cabal test all` from `core/` passed all 2,550 core cases on native x86_64
Windows 11 (`DESKTOP-R6BTBVS`), GHC 9.12.4 and Cabal 3.16.1.0. Both new cases passed. This Windows
run does not establish the POSIX permission-denied branch; the fixture keeps the case present and
asserts the actual kernel result on every gate host.

#### Remaining Work

None.

### Sprint 0.6: Every tracked text file has a declared line ending [Done]

**Status**: Done
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

On 2026-10-26, `git ls-files --eol` audited all 977 tracked files: every text file has an explicit
`eol=lf` or `eol=crlf` attribute, and every tracked non-script text file has `i/lf`. `.editorconfig`
reports `attr/text=auto eol=lf`. The change carries no line-ending churn. `AGENTS.md` and `CLAUDE.md`
already state the authoritative LF policy and need no text change.

The complete host static gate (§ JJ) passed on `DESKTOP-R6BTBVS`, native x86_64 Windows 11
10.0.26300.9457, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1, Python 3.14.7:

- `cabal test all` from `core/`: 2,550 core cases passed (387.19 seconds).
- `cabal test all` from `demo/`: 164 consumer cases passed (5.76 seconds) and the included 2,550 core
  cases passed (361.31 seconds). Both Cabal legs compile the provider-live component, which reports its
  declared unrequested-lane `Unsupported`; these runs establish no live provider acceptance.
- `poetry run python -m hostbootstrap.check_code`: Ruff, Black and strict mypy passed.
- `poetry run python -m hostbootstrap.test_all`: 251 cases passed (5.30 seconds).

The initial demo attempt stopped while printing a test title containing `§` through the command
console's CP437 encoding. The successful full demo command initializes that console with `chcp 65001`
and restores its original code page afterward; no case or assertion is removed. The demo driver's own
locale obligation is unchanged.

#### Remaining Work

None.

## Remaining Work

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
