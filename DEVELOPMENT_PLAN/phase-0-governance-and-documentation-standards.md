# Phase 0 — Governance and documentation standards

**Status**: Done
**Depends on**: nothing
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-11-05 ; hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` from `core/` ; pass ; covers in-gate

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
  `## Phase Objective` or `#### Validation

DocValidatorSpec's existing negative fixture proves the doctrine guards and their scoped absences.
Its ledger rows with no deleting-phase link remain exact refusals.

The split-sprint citation group adds five cases: an Active split beside its Done parent is recognized;
citing only the parent still refuses; an undefined sibling names its entire label and refuses;
multiple citations retain each label; and a longer suffix followed by possessive punctuation is
recognized. The implementation changes seven non-empty production Haskell lines in one module.
The classifier consumes the complete suffix before scanning the rest of the line. All other production
modules and all 702 compile-fail fixtures retain their baseline bytes.

On 2026-11-05, the closing documentation selection for the host-provider report sprint identifies
the truncated split label. All three native builds of the complete-label implementation pass with
GHC 9.12.4/Cabal 3.16.1.0. The first Windows documentation selection then identifies five unintended
Remaining Work edits in unrelated governance sprints; those five sections are restored byte-for-byte
from the baseline before the passing selections below. All 22 documentation cases pass on Linux and
Windows, including the live repository scan and the five new controls.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T15:30:29.499580+00:00 | 2026-11-05T15:31:27.276529+00:00 | 57.776946 | PASS; exit 0 |
| Linux demo build | 2026-11-05T15:30:29.481855+00:00 | 2026-11-05T15:30:59.125293+00:00 | 29.643439 | PASS; exit 0 |
| Windows core build | 2026-11-05T15:30:29.481774+00:00 | 2026-11-05T15:30:48.401923+00:00 | 18.920173 | PASS; exit 0 |
| Linux documentation selection | 2026-11-05T15:32:11.238582+00:00 | 2026-11-05T15:32:17.468036+00:00 | 6.229454 | 22 cases; exit 0 |
| Windows documentation selection | 2026-11-05T15:32:11.238525+00:00 | 2026-11-05T15:32:18.786670+00:00 | 7.548144 | 22 cases; exit 0 |

The declared governance gate and complete host-static gate are recorded below.

The declared governance gate passes on 2026-11-05: all 22 DocValidatorSpec cases run inside
the complete `cabal test all` from `core/`. The complete four-command host-static gate also passes
in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T15:33:05.069120+00:00 | 2026-11-05T15:43:34.912562+00:00 | 629.843441 | 4467 core cases, including all 22 DocValidatorSpec cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T15:33:05.068957+00:00 | 2026-11-05T15:43:10.106531+00:00 | 605.037575 | 4467 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T15:33:05.079968+00:00 | 2026-11-05T15:33:06.346134+00:00 | 1.266165 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T15:33:05.095227+00:00 | 2026-11-05T15:33:12.924129+00:00 | 7.828902 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both trees.
Python covers all 1585 statements and 460 branches. Cabal holds -Werror. The other 196 production
Haskell modules and all 702 compile-fail fixtures match the baseline. Changed files retain LF endings.

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
