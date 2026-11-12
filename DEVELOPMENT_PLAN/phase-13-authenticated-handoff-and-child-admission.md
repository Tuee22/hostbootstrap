# Phase 13 — Authenticated handoff and child admission

**Status**: Done
**Depends on**: Phase 12 (the step algebra and the single project plan)
**Substrates**: linux-cpu
**Gate**: `cabal test all -j1` from `core/`, after focused `HandoffSpec`,
public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec` runs
**Gate kind**: self-verifying
**Gate evidence**: 2026-11-03 ; linux x86_64 on retained Docker/WSL2, GHC 9.12.4, Cabal 3.16.1.0 / native Windows orchestration ; `cabal test all -j1 --test-show-details=direct --test-option=--hide-successes --test-option=--pattern '--test-option=/HandoffSpec/ || /public compile-fail boundaries/ || /indexed project-plan foundation/ || /DocValidatorSpec/'` ; pass ; covers in-gate
**Gate evidence**: 2026-11-03 ; linux x86_64 on retained Docker/WSL2, GHC 9.12.4, Cabal 3.16.1.0 / native Windows orchestration ; `cabal test all -j1 --test-show-details=direct --test-options=--hide-successes` ; pass ; covers in-gate

> **Purpose**: Define the bounded root-authenticated handoff and keyless rooted-transport contracts, and the
> frame-child entry with its one-transaction process bracket. The phase constructs no recursive child and
> claims no successful rooted process exchange.

## Phase Objective

The recursive lifecycle crosses machine boundaries from a host frame into VMs and containers. This phase
defines the authentication and bounded transport contracts used at that boundary. The root coordinator holds
the independently provisioned signing identity, a child issues a fresh challenge and verifies the root's exact
edge grant against the independently installed project key, and intermediate frames can relay canonical rooted
bytes without acquiring a signing key, protected store, or root command authority.

The wire distinguishes transported payload identity from child-configuration identity, authenticates scope
before untrusted bytes can introduce its phantom, and carries recovery config and adapter bytes as one
canonical package. The rooted request/response vocabulary includes the shapes later used by terminal receipt
exchange. The frame-crossing entry lets this binary recognize, before its parser, that it is the far side of
a frame crossing. Its one-transaction bracket launches that child in its own process group, exchanges one
request and one answer over the child's pipes, and ends and reaps the child's process tree. Phase 13 owns
only those authentication, codec, transport, and frame-crossing contracts. Phase 17 (the recursive lifecycle
command) owns the root catalog, retained session path, response production and fixed-signer invocation at
the root endpoint, durable prepare/settle/replay/receipt semantics, storeless frame execution, lifecycle
process ownership, and recursive command adoption. Recursive child construction, a successful rooted process exchange, and the
rooted service the root endpoint runs are that phase's too: this one validates the structure of a rooted
request and carries whatever answer comes back.

## Sprints

### Sprint 13.1: Public handoff binding and installed-key safety [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/UpdateHandoffBindingField.hs`,
`core/hostbootstrap-core/test/compile-fail/RelabelHandoffBindingGeneration.hs`
**Production budget**: at most 200 changed nonempty lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/unrepresentable_state.md`, `DEVELOPMENT_PLAN/rationale.md`

#### Objective

Seal the public challenge/grant binding and preserve independently installed key verification, with exact
public value-level evidence before opening a test-only route to any hidden transport implementation.

#### Deliverables

- Every edge retains one fresh `HandoffChallenge` and one one-use token commitment in canonical,
  length-delimited protocol-v1 bytes. `HandoffGrant` binds installed project, scope, plan revision, broker
  generation, parent/child edge, payload kind, verb, and lifecycle phase.
- A short-lived `RootBroker` narrows the provisioned project signing identity to one verified root
  invocation. Its grant transcript remains `frame("hostbootstrap/handoff-grant") <> frame(Word64BE 1) <>
  frame(installed verification-key digest) <> frame(canonical binding) <> exact token frame <>
  frame(challenge)`; its other fixed signing domains remain owned by their following sprints.
- `HandoffBinding` exports plain read-only functions under its current accessor names, with privately
  renamed record fields or a positional representation. External code cannot rewrite signed fields or
  relabel the `scope` and `brokerGeneration` phantoms through record update.
- Public binding/input/challenge parsers have exact refusal tables, every required input field and the
  payload-kind rendering variant are exercised, and a different well-formed token refuses its commitment.
- Each offer, broker, and grant independently redacts token bytes, signing seed, and verification-key bytes
  in every listed representation; each value independently carries its redaction marker.
- Child verification still consumes the independently installed project verification key and yields only
  `VerifiedHandoff scope brokerGeneration`; `verifyHandoff` recomputes received payload and token digests.
  Key reads catch `IOException` only, retaining typed unavailable-key errors while asynchronous exceptions
  propagate.

#### Validation

Run focused `HandoffSpec`, the actual public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec`,
then all four host static commands. Record actual commands, counts, outcomes, and changed production lines.
The phase's separate declared gate remains owed at phase closure.

Closure requires all of these public controls:

- `handoffBindingInputFromWire` round trip plus each exact refusal; `withHandoffBindingFromWire` over mutated
  canonical bindings with unknown payload kind, a 7-byte generation, empty required field, non-UTF-8 field,
  trailing bytes, and another installed project; `handoffChallengeFromBytes` with 31 and 33 bytes.
- The rendering-variants case includes `input{requestedPayloadKind = RecoveryAdapterWire}`. The required-field
  traversal sets each of `requestedSpecDigest`, `requestedPlanRevision`, `requestedParentFrame`,
  `requestedChildFrame`, `requestedChildConfigDigest`, and `requestedPhase` to empty in turn, requiring that
  field's exact `HandoffBindingMismatch` detail.
- Rebuild an otherwise valid offer around a different well-formed 32-byte token and require exactly
  `HandoffBindingMismatch "the received token does not match the bound token commitment"`.
- For each offer, broker, and grant separately, its `show` contains neither the offer's token bytes, the
  32-byte signing seed, nor the verification-key bytes in raw, hex, or `show` form, and contains its own
  redaction marker.
- Add `UpdateHandoffBindingField.hs` using `b { handoffChildFrame = "elsewhere" }` and
  `RelabelHandoffBindingGeneration.hs` using
  `b { handoffPhase = handoffPhase b } :: HandoffBinding scope g'`. Measure the unchanged subjects against
  the original field-export API before sealing, then against the sealed API. Register the actual named GHC
  refusal after measuring it; a remaining same-named plain getter does not justify a guessed
  field-not-in-scope diagnostic. Preserve all independent public compile-fail controls.
- A lexical source guard requires zero `SomeException` identifiers in `Handoff.hs`, and the existing missing,
  unreadable, and malformed signing/verification-key tests retain their typed refusals. Source inspection of
  the two actual read catches establishes the narrow exception category; no timing-based asynchronous
  injection or new key-reader seam is introduced.

The actual new `HandoffSpec` cases are "binding input round-trips and refuses malformed public request
bytes", "canonical bindings refuse malformed fields before delivery", "challenges require exactly
32 bytes", "a substituted well-formed token refuses its bound commitment" and "installed key reads
catch only IO exceptions". Existing "every caller-bound field and the token change canonical rendering",
"an empty required field is rejected before signing" and "Show and errors redact payload, token, and
key bytes" retain their controls and add the required variants and exact per-value assertions. Input
wire decoding remains structural; semantic required-field refusal belongs to the admitted binding
producer. Each value's actual opaque marker is asserted separately: offer `<redacted>`, broker
`<signing>`, grant `<signed>`.

2026-11-01: Production measures 114 nonempty lines (127 physical) in one module against the saved
baseline with autojunk disabled. The public test controls, registrations and two compiler subjects
measure 223 nonempty lines (229 physical), including the explicit test serializer dependency.
Reciprocal source and public-test reviews passed. Native
`cabal build all` passed with parent exit zero; its duration was not captured. Linux `cabal build all`
passed with parent exit zero in 29.60 seconds. Both public-only subjects compiled with exit zero
against the original record-field API on native Windows and Linux. After rebuilding, their identical
376- and 377-byte LF bodies were refused on both hosts with exit 1/GHC-22385, respectively
`Not in scope: record field 'handoffChildFrame'` and `Not in scope: record field 'handoffPhase'`.
Expectations were registered only after both actual after-probes. All 602 fixture files have exactly
one registration. Getter export names, equality, nominal roles and canonical field order are unchanged.
The initial focused builds on native Windows and Linux stopped before any core tests ran:
GHC-63394 under `-Wx-partial`/`-Werror` identified a partial `head fields` in the new fixture setup.
Both Cabal parents reported build failure and exited 1. The setup now uses an exhaustive match over
the actual decoded fields and explicitly fails if the required field is absent; byte-length mutation
and every expected refusal remain unchanged. Reciprocal review passed again. The repeated native
focus then failed six of 915 cases in 175.23 seconds; Linux failed the same six among 940 cases in
145.87 seconds. Both Cabal parents reported FAIL and exited 1. All new public controls, all 672 public
compiler controls and the remaining foundation/documentation/portability cases passed. The six
failures are whole-shared-facade hash and historical-size freezes: the thirteen ordinary readers add
26 significant declaration lines outside those guards' owned slices. Guard adoption narrows the
facade freezes to their actual owned definitions measured against the saved baseline, and separately
measures that reader block for historical attribution. A temporary external DATA utility evaluated the
existing `SourceGuard.haskellDefinitionClauseTokens` reader against saved and current text: all five
named-definition bundles matched exactly, using an unambiguous name/clause/token encoding. It compiled
no replacement Handoff identity and made no public-consumer proof claim. The existing owned response
section also matched byte-for-byte at 119 significant lines and 6,323 bytes. The original 240-line response budget and
all substantive import, producer, role, ordering and other-owner freezes remain in force. Independent
review verified that exactly six unowned whole-facade hashes were replaced, every other hash constant
remained unchanged, and the existing historical increment and budget assertions were preserved.
The six corrected guard cases plus all 17 documentation cases passed together on native Windows
in 13.55 seconds and Linux in 10.74 seconds: all 23 cases explicitly completed, both Cabal suites
reported PASS, and both parents exited zero. The next Linux whole selection failed one of 940 cases
in 143.98 seconds, with Cabal FAIL and parent exit 1: `PortabilitySpec` refused the new token-digest
helper's text re-encoding. All six corrected guard cases and the runtime, compiler, foundation and
documentation controls passed. The contemporaneous native selection passed all 915 cases in 170.81
seconds with Cabal PASS and parent exit zero; that selection did not include the portability group.
The byte contract now uses ordered JSON arrays for declaration data and original byte slices for
source sections. A native quick rebuild then refused the hidden `Data.Aeson` package (GHC-87110)
before tests ran; the test component now declares its direct `aeson` dependency, already used by the
library. The portability guard and all diagnostic expectations are unchanged. The combined six-guard,
17-documentation and 25-portability selection then passed all 48 cases on native Windows in 20.70
seconds and Linux in 16.65 seconds, both with explicit completion, Cabal PASS and parent exit zero.
Both complete focused selections include the portability group. The final native selection passed
all 940 cases in 180.64 seconds, with explicit completion, Cabal PASS and parent exit zero. Linux
passed all 940 cases in 141.84 seconds, with explicit completion, Cabal PASS and parent exit zero.
The full four-command Linux gate began on 2026-11-01 at 01:25:57 UTC. Python checks passed with
parent exit zero; all 376 Python tests passed in 5.85 seconds with 100% statement and branch coverage
and parent exit zero. Standalone core passed all 3,720 cases in 251.37 seconds, with explicit completion,
Cabal PASS and parent exit zero. Conditional accounting passed, including the actual filesystem-root
case. The demo's own 165 cases passed in 1.57 seconds, and its included core suite passed all 3,720
cases in 239.84 seconds. Both Cabal parents reported explicit completion and PASS; all four parents
exited zero. Conditional accounting passed in both core legs, including the actual filesystem-root
case. The final 871-file Haskell byte audit matched the native tree and all 602 fixture paths/bytes;
the process audit found no surviving tests or probes. The gate completed on 2026-11-01 at 01:32:27 UTC
on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. No physical-provider claim is made.
The final status and README closure passed all 17 `DocValidatorSpec` cases in 4.11 seconds on
2026-11-01 at 01:36:37–01:36:46 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were synchronized and source bytes remained unchanged.

#### Remaining Work

None.

### Sprint 13.2: Handoff source guards use lexical and component metadata [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: no production Haskell changes
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Make Handoff's structural supplements inspect actual module registrations and Haskell tokens before the
private ownership change, without letting comments, string contents, or collapsed source invent a match.

#### Deliverables

- One shared Cabal-seam helper examines module names from every component stanza field, tolerating commas
  and inline values; all whole-line absent-seam checks use it.
- A pure `fragmentsInOrder :: [String] -> String -> Either String ()` tokenizes source and fragments with
  `SourceGuard.haskellTokens`, consumes each fragment as one contiguous token run after the previous match,
  and returns the first unmatched fragment. The assertion wrapper includes that fragment in its failure.
- Every caller supplies source before whitespace collapse and uses whole-token fragments, with string
  literals explicitly quoted; partial-token and comment-only requirements are replaced by actual syntax.
- Pure regressions distinguish comments, identifiers, string-literal tokens, and ordered matches. Existing
  source/ownership guards remain structural supplements to real value-level cases.

#### Validation

Run `HandoffSpec`, the public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec`, followed by
all four host static commands. Record actual results; no production behavior or public API changes here.

`HandoffSpec` carries ten pure cases: `ordered fragments ignore line and nested block comments`,
`ordered fragments distinguish identifiers from complete string tokens`, `ordered fragments retain
layout-independent code and pragma tokens`, `ordered fragments require complete contiguous tokens`,
`ordered fragments report the first unmatched fragment`, `ordered fragments consume each matched
occurrence`, `ordered fragments refuse empty and comment-only requirements`, `Cabal seam checks see
inline and comma-separated registration fields`, `Cabal seam checks include common and conditional
registrations`, and `Cabal seam checks ignore comments and similarly named modules`.

The saved pre-change consumer baseline measures 526 changed nonempty lines (530 physical lines) in
one test module and no production Haskell changes. Review preserves all 153 existing ordered assertions
and their labels, changing only twelve diagnostic fragments to explicitly quoted complete string tokens;
every ordered assertion receives original source or an original section. All nine scheduled absent-module
loops compare parsed module names. Independent substring guards, producer/import counts, owned freezes,
and the separately owned derived-size assertions retain their subjects and expectations. Existing
`SourceGuard` readers are used without changes.

On 2026-11-01, native Windows with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test hostbootstrap-core-test --test-show-details=direct --test-option=--pattern=/HandoffSpec/`
from `core/`: all 128 cases passed in 31.45 seconds, with explicit completion, Cabal PASS and parent
exit zero. The test module and driver compiled under their default `-Werror` policy.
The x86_64 Linux focused selection passed all 950 cases in 133.31 seconds on 2026-11-01 at
01:42:41–01:45:16 UTC, including `HandoffSpec`, all 672 public compiler controls, the indexed project-plan
foundation, all 17 documentation cases and all 25 portability cases. Cabal reported explicit completion
and PASS, and the parent exited zero. Independent review confirmed all 1,063 existing ordered fragments,
all hash constants and producer/token counts, all 88 simple containment assertions and the derived-size
controls remain unchanged apart from the twelve explicitly quoted fragments. The complete Haskell
byte audit identifies only this test module as changed; all 602 compiler fixtures and the package manifest
retain their bytes.
The full four-command Linux gate passed on 2026-11-01 at 01:45:42–01:50:01 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,730 cases in 241.06 seconds. The demo passed its own 165
cases in 1.50 seconds and its included core suite passed all 3,730 cases in 237.97 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 supported-runner Python
tests passed in 5.56 seconds with 100% statement and branch coverage. All four parents exited zero.
Conditional accounting passed in both core legs, including the actual filesystem-root case. The final
871-file Haskell audit matched the validated snapshot, all 602 fixture paths and bytes remained unchanged,
and no test or probe children survived. The default provider-live wrapper was not requested; this gate
makes no physical-provider claim.
The final status/README closure passed all 17 `DocValidatorSpec` cases in 4.38 seconds on
2026-11-01 at 01:53:50?01:53:59 UTC, with explicit completion, Cabal PASS and parent exit zero; all
95 governed documents were byte-verified and the validated source snapshot remained unchanged.

The Cabal helper detects an absent seam if it is reintroduced in any stanza, including an inline or
comma-separated module list. `fragmentsInOrder ["ProjectUp"] "-- ProjectUp: refused\nx = y"` returns
`Left "ProjectUp"`; the same bare fragment against `x = "ProjectUp"` also returns `Left "ProjectUp"`, while
the quoted fragment `"\"ProjectUp\""` returns `Right ()`. A reversed fragment pair returns `Left` naming
the second fragment. The actual assertion callers no longer run `normalizeWhitespace` over raw source
before tokenization, including callers that previously stored a normalized local value.

#### Remaining Work

None.

### Sprint 13.3: Module-source guards follow declared physical homes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/SpecIndexSpec.hs`,
`core/hostbootstrap-core/test/StepSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Production budget**: no production Haskell changes
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Read the actual physical homes declared by the package before the bounded source relocations, preserving
independent ownership expectations and the existing production component scope.

#### Deliverables

- The twelve source-reading specs use the existing `SourceGuard.libraryModulePath` and shared inventories
  for actual module homes. Missing or ambiguous homes refuse; fabricated documentation-citation fixtures
  retain their deliberately synthetic paths.
- Production caller walks cover Main's registered modules and `library handoff-implementation-internal`
  when it is present, requiring each file to lie in its registered owner's effective roots. The separate
  completeness census retains undeclared physical files under independently pinned roots. Existing broad
  all-library audits retain their scope; Main-only allowlists do not widen to every private library.
- Physical ownership assertions use package-relative paths with independently reviewed expected literals.
  Before relocation their `src/` prefixes remain explicit; each relocation sprint adopts only its own
  expected paths. Neither invented logical paths nor expectations copied from observed lookups prove ownership.
- The public-export reader includes Main's bare, unrenamed reexports and reads their actual source owners.
  Its unchanged sealed-input policy requires six additional current ownership facade pins: `Ownership.Clause`,
  `Ownership.Object`, `Ownership.Posix`, `Ownership.Primitive`, `Ownership.Row`, and `Ownership.Windows`,
  all prefixed `HostBootstrap.`. Their literal export lists are reviewed; all 67 existing pins remain unchanged.
- Regressions cover a reexported facade's unchanged explicit exports and refusal when its export list changes,
  and retain missing/ambiguous-home and additional-root controls. The current effective-public inventory has
  104 members; the actual sealed-pin audit has 73 required entries with no missing or stale entry.
- Existing freezes, role controls, real compiler proofs, DATA identities and the nine Cabal-seam checks retain
  their subjects. This source-reading adoption supplies no hidden runtime test import or new authority route.

#### Validation

Run the affected source-ownership, sealed-export, Handoff, indexed project-plan, public compile-fail and
DocValidator cases, then all four host static commands. Record the actual cases, counts, exits and consumer
footprint. The two reexport regressions prove unchanged exports remain pinned and changed exports refuse;
existing physical-home controls continue to reject missing or duplicate module declarations.

The initial recut documentation check on 2026-11-01 at 01:59:32–01:59:39 UTC failed one of 17 cases
in 4.29 seconds, with Cabal FAIL and parent exit one: two implementation paths shared one malformed
inline-code span. The paths now use separate spans; the validator and source expectations are unchanged.
No source implementation began before this check.
The corrected recut passed all 17 `DocValidatorSpec` cases in 4.19 seconds on 2026-11-01 at
02:00:26–02:00:35 UTC, with explicit completion, Cabal PASS and parent exit zero. Independent review
verified 48 consecutive sprints, all 57 unique path pairs and the 17 Active / 28 Planned / 3 Done roll-up;
the 25 retained subsequent sprint sections differ only by their explicit sprint-citation shifts. Version
numbers, measured durations and existing completion evidence retain their values. All 95 governed documents
were byte-verified, and no source or package-description bytes changed during the recut.

The saved fourteen-file consumer baseline measures 2,018 changed nonempty test lines (2,031 physical
lines), with no production Haskell, package-description or compiler-fixture edits. Reciprocal review
preserves every existing case label, all 153 Handoff ordered assertions, lexical counts, hash constants,
owned freezes and independent caller/producer sets. All 67 prior export-pin literal blocks are unchanged;
six reviewed ownership-module pins extend the required set to 73. Existing broad all-library audits retain
their scope. Registered implementation inventories validate each physical home against its actual owner's
effective roots; registration completeness retains a separate physical census and independent expected roots.

`AuthoritySpec` carries eleven new regressions: `a reexported sealed facade keeps its reviewed export pin`,
`a changed reexported facade refuses its reviewed export pin`, `a missing common module stanza refuses
public enumeration`, `a cyclic common module stanza refuses public enumeration`, `common BuildInfo
modules do not become public library modules`, `library public fields cannot be inherited from common
BuildInfo`, `public enumeration refuses qualified or aliased Cabal reexports`, `implementation lookup
refuses a registration backed only by another owner's root`, `implementation lookup follows inherited
roots and other modules`, `implementation lookup includes only Main and the exact handoff owner`, and
`implementation lookup refuses one physical module registered to both owners`.

On 2026-11-01 at 02:13:28–02:18:46 UTC, x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0 passed
the focused selection across all twelve affected reader-spec groups, the public compiler boundaries,
documentation and portability: all 1,737 cases passed in 190.17 seconds, with explicit completion, Cabal
PASS and parent exit zero. Compilation and linking of the changed readers and dependent tests passed
under the default `-Werror` policy. The complete 871-file Haskell byte audit matched the frozen native
snapshot, and the package description and all 602 compiler fixtures retained their bytes.
The matching native Windows selection also passed all 1,737 cases in 273.53 seconds with GHC 9.12.4
and Cabal 3.16.1.0 on 2026-11-01, with explicit completion, Cabal PASS and parent exit zero. Its changed
readers and all dependent test modules compiled cleanly under the default `-Werror` policy; the native
source bytes remained identical to the frozen Linux snapshot.
The full four-command Linux gate passed on 2026-11-01 at 02:19:27–02:25:44 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 255.40 seconds. The demo passed its own 165
cases in 1.55 seconds and its included core suite passed all 3,741 cases in 244.45 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 supported-runner Python
tests passed in 5.90 seconds with 100% statement and branch coverage. All four parents exited zero.
Conditional accounting passed in both core legs, including the actual filesystem-root case. The final
871-file Haskell audit matched the validated native snapshot, all 602 compiler fixture paths and bytes
remained unchanged, and no test or probe children survived. The default provider-live component was not
requested; this gate makes no physical-provider claim.
The final status and README closure passed all 17 `DocValidatorSpec` cases in 3.83 seconds on
2026-11-01 at 02:26:33–02:26:41 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and the frozen source snapshot remained unchanged.

#### Remaining Work

None.

### Sprint 13.4: Private implementation source homes, cohort 1 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Authority/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Activation`, `HostBootstrap.Authority`, `HostBootstrap.Config.Authority.Internal`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Activation.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Authority.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Authority.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Config/Authority/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Authority/Internal.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main declares `internal/handoff-implementation` as an additional source root while retaining every
  existing module registration. The independent Main/library root expectations adopt that one actual root;
  no private handoff library is registered yet.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs have identical raw
bytes and SHA-256 after relocation; each original path is absent and each target declares its original
module exactly once. Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Activation` | 37,104 | 836 | `d0dfe6aa8e9a2184bbc270e2c05d2ccdc3bee5a76a0756d9a51e7de90e35824d` |
| `HostBootstrap.Authority` | 3,876 | 128 | `d88a3114ef6fddfefec5992b5968b747d6c7f2c12c893770c84378e8b317bf1d` |
| `HostBootstrap.Config.Authority.Internal` | 1,896 | 49 | `9a1fca9ab9c939cb2a4895ee1d09c5bca885345a2a47ed585da9c4d677804a62` |

This is three source-module relocations and zero changed Haskell content lines, totaling 42,876 bytes
and 1,013 physical lines. The four consumer files measure twelve changed nonempty lines (twelve physical):
two in the package description, six in `AuthoritySpec`, two in `SpecIndexSpec`, and two in `ProjectPlanSpec`.
Exact manifest comparison permits only Main's additional source root; module registrations, public exports,
dependencies and existing DATA-unit registrations remain unchanged. Current implementation links, the
ledger and governed references follow the actual targets. The already Active service-runtime phase's
explicit Activation coverage path follows its new home; no Done deferred phase covers these edits.
On 2026-11-01, native Windows `cabal build all` from `core/` passed in 25.171 seconds with parent exit
zero under the default `-Werror` policy. Build metadata identifies GHC 9.12.4 and Cabal 3.16.1.0; installed
registrations retain exactly one owner for each relocated module: Main exposes Activation and Authority
and hides Config.Authority.Internal. Its unit remains `hostbootstrap-core-0.1.0.0-inplace`, the fourteen
local core units are unchanged, and no handoff implementation unit is registered. This warm build reused
objects and reported no individual module-compilation lines; it establishes build and ownership evidence
without claiming fresh compilation of the three unchanged bodies.
The x86_64 Linux focused selection passed all 1,737 cases in 164.41 seconds on 2026-11-01 at
02:31:34–02:35:18 UTC, with explicit completion, Cabal PASS and parent exit zero. It covered all twelve
affected reader-spec groups, the public compiler boundaries, documentation and all 25 portability cases;
Main and the test components built cleanly. All 871 Haskell files matched the native snapshot, including
the three exact relocated contents with no old-path copies. The manifest matched its single-root change
and all 602 compiler fixture paths and bytes remained unchanged.
The full four-command Linux gate passed on 2026-11-01 at 02:35:50–02:40:57 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 258.78 seconds. The demo passed its own 165
cases in 1.70 seconds and its included core suite passed all 3,741 cases in 252.19 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 supported-runner Python
tests passed in 5.55 seconds with 100% statement and branch coverage. All four parents exited zero.
Conditional accounting passed in both core legs, including the actual filesystem-root case. The final
871-file Haskell audit matched the native snapshot; all three targets retained the saved byte lengths
and SHA-256 values, all old paths were absent, all 602 fixtures were unchanged, and no test or probe
children survived. The default provider-live component was not requested; no physical-provider claim
is made by this gate.
The final status and README closure passed all 17 `DocValidatorSpec` cases in 4.04 seconds on
2026-11-01 at 02:42:06–02:42:15 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and the relocation snapshot remained unchanged.

#### Remaining Work

None.

### Sprint 13.5: Private implementation source homes, cohort 2 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Class/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Fields.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Config.Class`, `HostBootstrap.Config.Class.Internal`, `HostBootstrap.Config.Fields`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Class.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Config/Class/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Class/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Fields.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs have identical raw
bytes and SHA-256 after relocation; each original path is absent and each target declares its original
module exactly once. Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Config.Class` | 16,860 | 441 | `dd0c214e2704eec3a72bc93f483a30a9245f4ff2ac5339ff6dc141956854827a` |
| `HostBootstrap.Config.Class.Internal` | 3,068 | 75 | `3dca20e6d24dd2aacf84ac09ed2817f487f12e9604b2ac35e03bf731de1173e2` |
| `HostBootstrap.Config.Fields` | 7,826 | 213 | `e7e6a6bf7ec2d7843eaf7eda0e20c1856ab300d82a528414ae63e6c132844b8f` |

This is three source-module relocations and zero changed Haskell content lines, totaling 27,754 bytes
and 729 physical lines. `SpecIndexSpec` contains exactly three reviewed path-literal replacements,
measuring six changed nonempty lines (six physical). The package description and `ProjectPlanSpec`
remain byte-identical: Main retains three roots, the library inventory retains fourteen roots, and all
module registrations, exports, dependencies and DATA-unit ownership remain unchanged. Independent
physical-header enumeration confirms one home per moved module. Current implementation paths in the
configuration, project-plan, lifecycle and service-runtime phase documents follow the actual targets;
no Done deferred evidence covers these edits.
On 2026-11-01, native Windows `cabal build all` from `core/` passed in 3.938 seconds with parent exit
zero under the default `-Werror` policy, using GHC 9.12.4 and Cabal 3.16.1.0. Installed registrations
uniquely assign Config.Class and Config.Fields as exposed Main modules and Config.Class.Internal as
hidden in the same `hostbootstrap-core-0.1.0.0-inplace` unit; fourteen local core units remain and no
handoff private unit exists. This warm build reused interfaces and reported no individual compilation
lines, so it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 02:45:46?02:50:32 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 274.68 seconds. The demo passed its own 165
cases in 1.59 seconds and its included core suite passed all 3,741 cases in 274.42 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 supported-runner Python
tests passed in 5.59 seconds with 100% statement and branch coverage. All four parents exited zero.
Conditional accounting passed in both core legs, including the actual filesystem-root case. The default
provider-live component was not requested; no physical-provider claim is made by this gate.
The final audit matched all 871 native/snapshot Haskell files, the unchanged package description and all
602 compiler fixture paths and bytes. All three relocated Config targets retained the saved byte lengths
and SHA-256 values, all old paths were absent, and no test or probe children survived.

The final status and README closure passed all 17 `DocValidatorSpec` cases in 4.03 seconds on
2026-11-01 at 02:51:20?02:51:28 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and the relocation snapshot remained unchanged.

#### Remaining Work

None.

### Sprint 13.6: Private implementation source homes, cohort 3 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Fields/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Install/Native.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Config.Fields.Internal`, `HostBootstrap.Config.Install.Native`, `HostBootstrap.Config.Schema`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Config/Fields/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Fields/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Config/Install/Native.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Install/Native.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs have identical raw
bytes and SHA-256 after relocation; each original path is absent and each target declares its original
module exactly once. Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Config.Fields.Internal` | 3,654 | 117 | `1bcfde016adacc354a394f34dc1bddce227da4e553474c7843cc120281f4eca2` |
| `HostBootstrap.Config.Install.Native` | 3,428 | 80 | `1235a4ada1a0b62a506b28ab6b210e999c8efad53381984fa3623aea876dfc42` |
| `HostBootstrap.Config.Schema` | 43,364 | 1,054 | `5265048b4db70661430dd1f466affd46dfbaf960e4dab5f6f9951a8ed22427a5` |

This is three source-module relocations and zero changed Haskell content lines, totaling 50,446 bytes
and 1,251 physical lines. No test-source or package-metadata edits are needed: the actual lookup readers
follow their new homes, and Main's three roots, the fourteen library roots, registrations, public exports,
dependencies and DATA-unit ownership remain unchanged. Current implementation links and canonical source
references follow the targets. The already Active test/context-command phase's explicit Schema coverage
path follows its actual home; no Done deferred evidence expires. Native's Windows header is a system
header, and Schema reads runtime-supplied paths; neither depends on its repository source-file location.

On 2026-11-01, native Windows `cabal build all` from `core/` passed in 3.406 seconds with parent exit
zero under the default `-Werror` policy, using GHC 9.12.4 and Cabal 3.16.1.0. Installed registrations
uniquely retain Fields.Internal and Install.Native as hidden Main modules and Schema as exposed in
`hostbootstrap-core-0.1.0.0-inplace`; fourteen local core units remain and no handoff private unit exists.
The warm build reused interfaces and reported no individual compilation lines, so no fresh
body-compilation claim is made.

The full four-command Linux gate passed on 2026-11-01 at 02:54:30?02:59:00 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 262.42 seconds. The demo passed its own 165
cases in 1.49 seconds and its included core suite passed all 3,741 cases in 263.19 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 supported-runner Python
tests passed in 5.47 seconds with 100% statement and branch coverage. All four parents exited zero.
Conditional accounting passed in both core legs, including the actual filesystem-root case. The default
provider-live component was not requested; no physical-provider claim is made by this gate.
The final audit matched all 871 native/snapshot Haskell files, all 689 saved test/manifest files, the
unchanged package description and all 602 compiler fixture paths and bytes. All three relocated targets
retained their saved byte lengths and SHA-256 values, all old paths were absent, and no test or probe
children survived.

The final status and README closure passed all 17 `DocValidatorSpec` cases in 3.87 seconds on
2026-11-01 at 02:59:51?02:59:59 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and the relocation snapshot remained unchanged.

#### Remaining Work

None.

### Sprint 13.7: Private implementation source homes, cohort 4 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Vocab.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `hostbootstrap/cli.py`, `tests/test_cli.py`,
affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Config.Schema.Internal`, `HostBootstrap.Config.Vocab`, `HostBootstrap.Context`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Config/Schema/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Vocab.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Context.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Context.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Python's named formatter exclusion in `hostbootstrap/cli.py` follows the actual `Context.hs` path,
  with its affected Python assertions. That covered-source edit expires the deferred Python-floor evidence: set
  Phase 1 Active in the same change, use its own Python-quality sprint for its declared gate and fresh covers
  digest, and restore its Done status before proceeding with this cohort's closure.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs retain identical raw
bytes and SHA-256; each original path is absent and each target declares its original module exactly once.
Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Config.Schema.Internal` | 4,076 | 111 | `70e2b419c73a61a9b5fb87151aa069bf7ccd21ea490f60236cd62512f2d82f82` |
| `HostBootstrap.Config.Vocab` | 8,042 | 246 | `19fb7d1794140755dc9fc2b39a8af0c1f09f9dc89582c86f1918e2e818daa535` |
| `HostBootstrap.Context` | 51,626 | 1,281 | `a969de6ad594a16c0eafadab0b1f5e468f5698d8d7cb3a15d76a41ed1b0386f4` |

This is three source-module relocations and zero changed Haskell content lines, totaling 63,744 bytes
and 1,638 physical lines. The consumer footprint is 32 changed nonempty lines (32 physical): four in
`SpecIndexSpec`, two in `hostbootstrap/cli.py`, and 26 in `tests/test_cli.py`. Only the two actual Schema
owner paths change in SpecIndex; Authority's synthetic Config.Vocab graph paths remain unchanged. The
Python formatter retains its exact named exclusions and roots, with Context's entry following its actual
home. The existing `test_style_gates_enumerate_sources_and_skip_the_modules_fourmolu_cannot_read` case
checks the relocated Context is omitted, an ordinary neighbour is included, and the old Context path is
included, while retaining its Registry, Network, demo and linter-root controls. It exercises the actual
source enumerator, not a formatter invocation.

The Haskell CPP body remains byte-identical. Main's three roots, the fourteen library roots, the package
description, exports, dependencies and DATA registrations are unchanged; 710 other source hashes match
the saved baseline. Current governed references and the already Active test/context phase's Context cover
path follow the actual homes. The covered Python edit expires the Python-floor completion evidence;
Phase 1 and its existing quality sprint own the re-run and fresh digest in the same change.

On 2026-11-01 the Python-floor phase's own two-command gate passes in order on both hosts before this
cohort's remaining validation. Linux checks exit zero; all 376 unfiltered Python tests pass in 5.34 seconds
with 100% statement and branch coverage and parent exit zero (03:07:10-03:07:21 UTC). Native Windows
checks also exit zero and all 376 unfiltered tests pass in 5.86 seconds with 100% coverage and parent exit
zero. After those commands pass, the actual compiled canonical digest helper independently measures
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` on each host. Phase 1 and its
quality sprint are Done again with current evidence and no remaining work; no stale deferred evidence
row is retained as current. The owning sprint records the host/toolchain, exact commands and measurements.

The restored Python-floor status and current deferred evidence passed all 17 `DocValidatorSpec` cases
in 4.10 seconds on 2026-11-01 at 03:10:51-03:11:07 UTC, with explicit completion, Cabal PASS and
parent exit zero. The current header contains exactly one gate-evidence row with the freshly measured
digest, and all covered Python bytes remain unchanged after the successful gate.

Native Windows `cabal build all` from `core/` also passed in 4.037 seconds with parent exit zero under
GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Installed metadata uniquely retains Schema.Internal
as hidden and Config.Vocab and Context as exposed in Main `hostbootstrap-core-0.1.0.0-inplace`.
Fourteen local units remain, with no handoff implementation unit. This warm build reused interfaces and
reported no individual compilation lines, so it makes no fresh body-compilation claim.

The full four-command Linux cohort gate passed on 2026-11-01 at 03:12:17-03:16:45 UTC with GHC 9.12.4
and Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 255.11 seconds. The demo passed its own
165 cases in 1.61 seconds and its included core suite passed all 3,741 cases in 255.76 seconds. Both
Cabal parents reported explicit completion and PASS. Fresh cohort executions of both Python commands
also passed: all 376 unfiltered tests passed in 5.46 seconds with 100% statement and branch coverage;
checks and all four parents exited zero. These Python runs are separate from the Python-floor phase's
own declared-gate executions. Conditional accounting passed in both core legs, including the actual
filesystem-root case. The default provider-live component was not requested; this gate makes no
physical-provider claim.
After the cohort gate, the compiled canonical digest still measures
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 03:16:59 UTC, exit zero
in 0.187309177 seconds with empty stderr, preserving the Python-floor evidence. The final audit matches
all 871 native/snapshot Haskell files, the unchanged package description, all 710 untouched baseline files,
all 602 compiler fixtures and all 26 covered Python files. Each relocated target retains its saved bytes
and SHA-256, old paths are absent, and no test or probe children survive.

The final status and README closure passed all 17 `DocValidatorSpec` cases in 3.98 seconds on
2026-11-01 at 03:17:38-03:17:46 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and Phase 1 retained its current covered-source evidence.

#### Remaining Work

None.

### Sprint 13.8: Private implementation source homes, cohort 5 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Dhall/Gen.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Dhall/Hoist.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Dhall.Gen`, `HostBootstrap.Dhall.Hoist`, `HostBootstrap.Handoff`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Dhall/Gen.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Dhall/Hoist.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Dhall/Hoist.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs retain identical raw
bytes and SHA-256; each original path is absent and each target declares its original module exactly once.
Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Dhall.Gen` | 8,581 | 231 | `571afb75e78b71e95c7cab73a40cb2ed3092ff254f5cbb8236de8e7274a7a73a` |
| `HostBootstrap.Dhall.Hoist` | 4,229 | 105 | `06e16cfaaa5a2d077cc750acbee43ab3f9cabda133d17e6a4005aed55ce0c75b` |
| `HostBootstrap.Handoff` | 200,458 | 4,448 | `3260373b58422a0255637f3ec8573108246266ed9bd28ba55dfcf4754b271832` |

This is three source-module relocations and zero changed Haskell content lines, totaling 213,268 bytes
and 4,784 physical lines. The consumer footprint is 164 changed nonempty lines (164 physical): 162 in
`HandoffSpec` and two in `AuthoritySpec`. All text outside 63 reviewed Handoff physical-path arrays is
byte-identical to the baseline. Each array retains its exact independently named members and multiplicities
after the path substitution; only eighteen arrays are reordered, matching their actual explicitly sorted
ownership results. No wire, FSM or execution-order array changes. Authority has only its one path replacement.

All 153 ordered-fragment requirements, lexical counts, 64-hex literal multiplicities, five owned Aeson
clause-bundle freezes and helper definitions remain unchanged. The raw response-authentication slice is
still 6,323 bytes with its original hash, and the ordinary-reader attribution is still thirteen signatures
and 26 significant lines. All six captured metadata/Python texts and 711 other source hashes match;
Main's three roots, the fourteen library roots, registrations, exports, dependencies and DATA ownership
are unchanged. Current implementation links and ledger references follow the actual targets. No covered
Python input or Done deferred evidence changes.

On 2026-11-01, native Windows `cabal build all` from `core/` passed in 3.711 seconds with parent exit
zero under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Installed registrations uniquely retain
Dhall.Gen, Dhall.Hoist and Handoff as exposed Main modules in `hostbootstrap-core-0.1.0.0-inplace`.
Fourteen local units remain and no handoff implementation unit exists. This warm build reused
interfaces and reported no individual compilation lines, so it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 03:25:09-03:30:07 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 254.38 seconds. The demo passed its own 165
cases in 1.45 seconds and its included core suite passed all 3,741 cases in 255.67 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
5.07 seconds with 100% statement and branch coverage. All four parents exited zero. Conditional
accounting passed in both core legs, including the actual filesystem-root case. The default provider-live
component was not requested; no physical-provider claim is made by this gate.
The final audit matches all 871 native/snapshot Haskell files, the package description, all 711 untouched
files, six metadata/Python snapshots and all 602 compiler fixtures. All moved targets retain their saved
bytes and hashes; old paths are absent. Fixed hash multiplicities, owned clause-bundle helpers and the raw
response section remain unchanged. The canonical compiled Python covers digest still measures
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 03:30:15 UTC, exit zero
in 0.178196958 seconds with empty stderr. No test or probe children survive.

The final status and README closure passed all 17 `DocValidatorSpec` cases in 3.89 seconds on
2026-11-01 at 03:31:12-03:31:20 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and Phase 1 retained its current covered-source evidence.

#### Remaining Work

None.

### Sprint 13.9: Private implementation source homes, cohort 6 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Handoff.Internal`, `HostBootstrap.Handoff.Protocol`, `HostBootstrap.Handoff.Receiver`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs retain identical raw
bytes and SHA-256; each original path is absent and each target declares its original module exactly once.
Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Handoff.Internal` | 1,783 | 42 | `214b1138f2a4a06e23839ab1600055a4d7611eb0d60eac643aa06a7420259dbc` |
| `HostBootstrap.Handoff.Protocol` | 31,720 | 739 | `59efed93557ddea190940e0b78acbfae120da8dc5b168eb6df0b833d2fc6d454` |
| `HostBootstrap.Handoff.Receiver` | 41,504 | 950 | `40b9686dc16bd183a64702366871f78ff5d4d51bc724e75f6e41b1f79d17b6b5` |

This is three source-module relocations and zero changed Haskell content lines, totaling 75,007 bytes
and 1,731 physical lines. `HandoffSpec` is the only consumer edit, measuring 72 changed nonempty lines
(72 physical). Its 31 reviewed ownership arrays retain exact independently named members and multiplicities
under 32 path substitutions; only eleven explicitly sorted ownership arrays are reordered, while the
other twenty retain their order. All text outside those arrays is byte-identical, including all 153 ordered
requirements, wire/FSM arrays, privacy/import/count assertions, reader attribution and clause-bundle helpers.
All hash-literal multiplicities, the raw response slice and the public Handoff body retain their saved bytes.

Nine captured metadata/Python texts and 712 other source hashes remain unchanged. The different module
`ProjectPlan.Handoff.Internal` is untouched. Main's three roots, the fourteen library roots, its hidden
registrations, public-import refusals, exports, dependencies and DATA ownership remain unchanged; no new
private unit or test import is introduced. Current implementation and ledger references follow actual homes.
No covered Python input or Done deferred evidence changes.

On 2026-11-01, native Windows `cabal build all` from `core/` passed in 3.535 seconds with parent exit
zero under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Installed registrations uniquely retain
Handoff.Internal, Handoff.Protocol and Handoff.Receiver as hidden Main modules in
`hostbootstrap-core-0.1.0.0-inplace`. Fourteen local units remain and no handoff implementation unit
exists. This warm build reused interfaces and reported no individual compilation lines, so it makes no
fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 03:35:57-03:40:52 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 269.66 seconds. The demo passed its own 165
cases in 1.50 seconds and its included core suite passed all 3,741 cases in 268.58 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
5.15 seconds with 100% statement and branch coverage. All four parents exited zero. Conditional
accounting passed in both core legs, including the actual filesystem-root case. The default provider-live
component was not requested; no physical-provider claim is made by this gate.
The final frozen-subject audit confirms 31 affected arrays, 32 path substitutions and eleven reorderings
with exact members, unchanged outside-array code, all fixed hashes, the reader block and raw response.
All 871 native/snapshot Haskell files, the unchanged package description, 712 untouched files, nine
metadata/Python snapshots and all 602 compiler fixtures match. Moved targets retain saved bytes and
hashes, old paths are absent, and no test or probe children survive. The canonical compiled Python
covers digest remains `43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at
03:41:06 UTC, exit zero in 0.188892754 seconds with empty stderr.

The final status and README closure passed all 17 `DocValidatorSpec` cases in 4.34 seconds on
2026-11-01 at 03:41:44-03:41:53 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and Phase 1 retained its current covered-source evidence.

#### Remaining Work

None.

### Sprint 13.10: Private implementation source homes, cohort 7 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Recovery.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Handoff.Receiver.Internal`, `HostBootstrap.Handoff.Recovery`, `HostBootstrap.Handoff.Relay`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Recovery.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Recovery.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs retain identical raw
bytes and SHA-256; each original path is absent and each target declares its original module exactly once.
Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Handoff.Receiver.Internal` | 7,850 | 263 | `a28ed069bc4434cf4b8eac69271d202e4b164190754cf52c7ca5f20d9d7fc5d8` |
| `HostBootstrap.Handoff.Recovery` | 3,865 | 101 | `815f5f78ecc803d3749a3aedd3dea52d3e6123a22b059ac1ecce983f6d5453dc` |
| `HostBootstrap.Handoff.Relay` | 144,058 | 3,258 | `be64e476a096175be9f2afadec3b5e706bcc477717ac392a777d62f029e0e5a5` |

This is three source-module relocations and zero changed Haskell content lines, totaling 155,773 bytes
and 3,622 physical lines. The consumer footprint is 200 changed nonempty lines (200 physical): 198 in
`HandoffSpec` and two in `ProjectPlanSpec`. The 73 reviewed ownership arrays retain exact independently
named members and multiplicities under ninety path substitutions; only 34 explicitly sorted ownership
arrays are reordered, and the other 39 retain their order. All text outside those arrays is byte-identical.
ProjectPlan has only its one actual Relay expected-home replacement.

All fixed hash-literal multiplicities, 153 ordered requirements, wire/FSM/privacy/import/count text,
root Handoff body, named clause-bundle helpers and 26-reader attribution remain unchanged. Relay's three
owned raw sections remain 1,778, 3,438 and 2,514 bytes with their original concatenated hash; the raw
response slice remains 6,323 bytes with its original hash. Eight captured metadata snapshots and 711
other source byte lengths and hashes match the saved baseline. Main's three roots, the fourteen library
roots, all registrations, exports, dependencies, DATA units and Python covered inputs are unchanged.
Current implementation and ledger paths follow the actual homes; no Done deferred evidence changes.

On 2026-11-01, native Windows `cabal build all` from `core/` passed in 3.744 seconds with parent exit
zero under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Installed registrations uniquely retain
Receiver.Internal, Recovery and Relay as hidden Main modules in `hostbootstrap-core-0.1.0.0-inplace`.
Fourteen local units remain and no handoff implementation unit exists. This warm build reused
interfaces and reported no individual compilation lines, so it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 03:49:26-03:54:20 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 256.30 seconds. The demo passed its own 165
cases in 1.35 seconds and its included core suite passed all 3,741 cases in 254.43 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
4.98 seconds with 100% statement and branch coverage. All four parents exited zero. Conditional
accounting passed in both core legs, including the actual filesystem-root case. The default provider-live
component was not requested; no physical-provider claim is made by this gate.
The final frozen audit confirms 73 affected arrays, ninety substitutions and 34 reorderings with exact
members and unchanged outside-array code. Relay's three raw sections, the response slice and public
Handoff body retain their original bytes and hashes. All 871 native/snapshot Haskell files, the unchanged
package description, 711 untouched files, eight metadata/Python snapshots and all 602 fixtures match;
moved targets retain saved bytes, old paths are absent, and no test or probe children survive. The
canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 03:54:33 UTC, exit zero
in 0.253167804 seconds with empty stderr.

The final status and README closure passed all 17 `DocValidatorSpec` cases in 3.95 seconds on
2026-11-01 at 03:55:27-03:55:36 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents were byte-verified and Phase 1 retained its current covered-source evidence.

#### Remaining Work

None.

### Sprint 13.11: Private implementation source homes, cohort 8 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Handoff.Rooted`, `HostBootstrap.Handoff.Runtime`, `HostBootstrap.Harness`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Rooted.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Handoff/Runtime.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Harness.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Harness.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs retain identical raw
bytes and SHA-256; each original path is absent and each target declares its original module exactly once.
Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Handoff.Rooted` | 46,335 | 875 | `55cede42469173f8a1523d5ee93ff3657342ae2317c46f84f8feb4e4b4504354` |
| `HostBootstrap.Handoff.Runtime` | 12,710 | 297 | `48d8d5be2b9694744e0f67571d89baf08576ec86f91f87809ee3119954439bd4` |
| `HostBootstrap.Harness` | 40,481 | 948 | `158f8149c432ca71ae2367f07b9583a75ee179a37e16031ddb926838f1abe16c` |

This is three source-module relocations and zero changed Haskell content lines, totaling 99,526 bytes
and 2,120 physical lines. The consumer footprint is 34 changed nonempty lines (34 physical): thirty in
`HandoffSpec`, two in `AuthoritySpec`, and two in `ProjectPlanSpec`. Fourteen reviewed Handoff ownership
arrays retain exact members and multiplicities under fourteen substitutions; only six explicitly sorted
arrays are reordered and the other eight keep their order. All outside-array text is byte-identical.
Authority and ProjectPlan each change only their actual Runtime expected-home literal.

All fixed hashes, 153 ordered requirements, Rooted's historical/current line and digest controls,
Runtime's export/nominal/two-arm/size guards, privacy/import assertions, owned raw response and Relay
sections, and the 26-reader attribution remain unchanged. Twelve metadata snapshots and 893 other
source byte lengths and hashes match the saved baseline. Main's three roots, fourteen library roots,
public Harness/hidden Rooted and Runtime registrations, dependencies, DATA components and covered
Python inputs are unchanged. Current implementation and ledger paths follow the targets; the already
Active harness phase's explicit coverage path follows Harness without a fresh deferred-gate claim.

On 2026-11-01, native Windows `cabal build all` from `core/` passed in 3.429 seconds with parent exit
zero under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Installed registrations uniquely retain
Rooted and Runtime as hidden and Harness as exposed in Main `hostbootstrap-core-0.1.0.0-inplace`.
Fourteen local units remain and no handoff implementation unit exists. This warm build reused
interfaces and reported no individual compilation lines, so it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 04:03:20-04:08:40 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 263.57 seconds. The demo passed its own 165
cases in 1.48 seconds and its included core suite passed all 3,741 cases in 262.20 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
5.23 seconds with 100% statement and branch coverage. All four parents exited zero. Conditional
accounting passed in both core legs, including the actual filesystem-root case. The default provider-live
component was not requested; no physical-provider claim is made by this gate.
The final frozen audit confirms fourteen affected arrays and substitutions, six reorderings with exact
members, unchanged outside-array code, and the single Runtime-home replacement in each other consumer.
Saved Rooted hashes, all reader/hash controls and raw response/Relay sections remain exact. All 871
native/snapshot Haskell files, the package description, 893 untouched files, twelve metadata/Python
snapshots and all 602 fixtures match; moved targets retain saved bytes, old paths are absent, and no
test or probe children survive. The canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 04:08:55 UTC, exit zero
in 0.203812206 seconds with empty stderr. The canonical package-stanza table also names Main's actual
third source root; no package metadata changes in this cohort.

The final status and README closure passed all 17 `DocValidatorSpec` cases in 4.11 seconds on
2026-11-01 at 04:09:55-04:10:03 UTC, with explicit completion, Cabal PASS and parent exit zero;
all 95 governed documents, including the package-layout root correction, were byte-verified and Phase 1
retained its current covered-source evidence.

#### Remaining Work

None.

### Sprint 13.12: Private implementation source homes, cohort 9 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/HostConfig.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Closure.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.HostConfig`, `HostBootstrap.HostTool`, `HostBootstrap.Lifecycle.Closure`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/HostConfig.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/HostConfig.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/HostTool.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Closure.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Closure.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs retain identical raw
bytes and SHA-256; each original path is absent and each target declares its original module exactly once.
Paths in the deliverables above name the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.HostConfig` | 3,887 | 100 | `231d381df7e06aeb35e1a2a86bec8b97bffd73369d18701582eddd88a230c7f2` |
| `HostBootstrap.HostTool` | 13,588 | 380 | `e9a9c6a12dcf5382eb54df3c16a2f0e2f9b9e3c4721ff812b088219f9d94bc7e` |
| `HostBootstrap.Lifecycle.Closure` | 247 | 7 | `3de2ca647ec87cf8f55dd527889292f82632c27abcf00e4ec29afc60fb7bf4d7` |

This is three source-module relocations and zero changed Haskell content lines, totaling 17,722 bytes
and 487 physical lines. The only consumer edit is one real Closure expected-home replacement in
`AuthoritySpec`, measuring two changed nonempty lines (two physical). Ten captured metadata texts and
895 other source byte lengths and hashes match the baseline, including the full `DocValidatorSpec`
synthetic HostTool citation fixtures. Those independent synthetic paths retain their original purpose.
All Handoff arrays and freezes, public exports, Main's three roots, fourteen library roots, dependencies,
DATA units and Python covered inputs remain unchanged. Existing Main registrations continue to expose
HostConfig, HostTool and Lifecycle.Closure. Current implementation and canonical source links follow the
actual homes; no Done deferred evidence expires.

On 2026-11-01, native Windows `cabal build all` from `core/` passed in 3.637 seconds with parent exit
zero under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Actual installed metadata uniquely retains
all three modules as exposed by Main `hostbootstrap-core-0.1.0.0-inplace`, including Lifecycle.Closure;
its unchanged package-description registration is authoritative. Fourteen local units remain and no
handoff implementation unit exists. This warm build reused interfaces and reported no individual
compilation lines, so it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 04:13:06-04:18:01 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 263.63 seconds. The demo passed its own 165
cases in 1.56 seconds and its included core suite passed all 3,741 cases in 262.01 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
4.97 seconds with 100% statement and branch coverage. All four parents exited zero. Conditional
accounting passed in both core legs, including the actual filesystem-root case. The default provider-live
component was not requested; no physical-provider claim is made by this gate.
The final audit matches all 871 native/snapshot Haskell files, the package description, 895 untouched
files, ten metadata/Python snapshots and all 602 compiler fixtures. The full DocValidatorSpec remains
saved-identical, including its original synthetic HostTool paths; Authority changes only the actual
Closure home. All moved targets retain saved bytes and hashes, old paths are absent, and no test or
probe children survive. The canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 04:18:12 UTC, exit zero
in 0.190786376 seconds with empty stderr.

The post-closure documentation check passed all 17 cases in 4.02 seconds on 2026-11-01 at
04:19:14-04:19:22 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next cohort began.

#### Remaining Work

None.

### Sprint 13.13: Private implementation source homes, cohort 10 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Context.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Context/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Lifecycle.Context`, `HostBootstrap.Lifecycle.Context.Internal`, `HostBootstrap.Lifecycle.Dependency.Internal`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Context.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Context.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Context/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Context/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Dependency/Internal.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- The existing `lifecycle-dependency-internal` DATA library follows its dependency module to the new
  source root. Its separate audited DATA identity and exports remain unchanged; this creates no third copy.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies these three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Lifecycle.Context` | 4,986 | 132 | `b5b1e5f35d81d75378e3c108b11f5e0f3248af31b3258adb752e8707afd93f19` |
| `HostBootstrap.Lifecycle.Context.Internal` | 7,304 | 182 | `189e16ff3cc62f60eb2933e1c0363036f5f13e74125a066be2cb724b256a557a` |
| `HostBootstrap.Lifecycle.Dependency.Internal` | 36,695 | 762 | `a9230ed53f5478fd3319480674413b8a493ab08f0c4cd716151e8e9534cc97cc` |

This is three source-module relocations and zero changed Haskell content lines, totaling 48,985 bytes
and 1,076 physical lines. The only consumer edit changes the existing
`library lifecycle-dependency-internal` source directory from `src` to `internal/handoff-implementation`,
measuring two changed nonempty metadata lines (two physical). Its unit identity, private visibility,
single exposed Dependency.Internal module, dependencies and existing test dependency remain unchanged.
Main retains its own hidden Dependency.Internal registration and no dependency on that DATA unit:
exactly the two audited compiled identities share one physical source, with no third copy. Main's
three roots and the fourteen library roots remain unchanged. Thirteen captured metadata texts and
896 other source byte lengths and hashes match the baseline; every test and Python input is unchanged.
Current governed paths and the DATA library's documented source-directory cell follow the actual homes.
No Done deferred phase's covered inputs change.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
25.079 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Cabal reconfigured its existing
components after the metadata change. Actual installed metadata retains Context exposed and
Context.Internal hidden uniquely in Main; Dependency.Internal has exactly its two existing identities,
hidden in Main and exposed by `lifecycle-dependency-internal`. Main's actual dependency set excludes that
DATA unit. Fourteen local units remain, with no handoff implementation unit. The warm build reported
no individual compilation lines and makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 04:24:22-04:28:55 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 242.56 seconds. The demo passed its own 165
cases in 1.49 seconds and its included core suite passed all 3,741 cases in 242.72 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
5.05 seconds with 100% statement and branch coverage. All four parents exited zero. Both core legs
passed conditional accounting, including the actual filesystem-root case. The default provider-live
component was not requested; this gate makes no physical-provider claim.

The final audit at 04:29:33 UTC matches all 871 native/snapshot Haskell files, the exact package-description
field change, 896 untouched files, thirteen metadata/Python snapshots and all 602 compiler fixtures.
All three targets retain their saved bytes and hashes, old paths are absent, and no test or probe children
survive. The canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 04:29:21 UTC, exit zero
in 0.182472389 seconds with empty stderr.

The post-closure documentation check passed all 17 cases in 3.90 seconds on 2026-11-01 at
04:30:32-04:30:42 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next cohort began.

#### Remaining Work

None.

### Sprint 13.14: Private implementation source homes, cohort 11 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Lifecycle.Execution`, `HostBootstrap.Lifecycle.Execution.Internal`, `HostBootstrap.Lifecycle.Mode`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Lifecycle.Execution` | 5,935 | 135 | `97276d6d7f90836631b150d45fab4154275aef3b9c886e37acba3795a4c132c9` |
| `HostBootstrap.Lifecycle.Execution.Internal` | 19,254 | 448 | `a1efcd22da3b408bc70c0413ac2ab94d509c18196e29fa05b88580626a7e582c` |
| `HostBootstrap.Lifecycle.Mode` | 487,055 | 10,111 | `5c0fe839514aa97ff0aaef3905f9852d3214f0f65b2cd57431ec5b489fc5ab80` |

This is three source-module relocations and zero changed Haskell content lines, totaling 512,244 bytes
and 10,694 physical lines. The only consumer edits replace two actual Mode paths in `AuthoritySpec`
and one independent Mode home in `ProjectPlanSpec`, measuring six changed nonempty lines (six physical).
Exact replacement comparisons preserve every other byte of both consumers. Thirteen captured
metadata/control texts and 894 other source byte lengths and hashes match the baseline, including
all Handoff arrays, reifier counts, prepared-entry/live-binding checks, roles, producers and frozen subjects.
Cabal, Main's three roots, fourteen library roots, DATA identities and every Python input remain unchanged.
Current governed paths follow the actual homes; the authority phase's caller-scope paragraph names its
already implemented all-library-root scan. No Done deferred phase's covered inputs change.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
3.422 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Actual installed metadata retains
Execution and Mode exposed uniquely by Main, with Execution.Internal uniquely Main-hidden. Fourteen
local units remain and no handoff implementation unit exists. This warm build reported library and
executable preprocessing/building with no individual compilation lines; it makes no fresh body-compilation
claim.

The full four-command Linux gate passed on 2026-11-01 at 04:33:14-04:38:15 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 256.05 seconds. The demo passed its own 165
cases in 1.44 seconds and its included core suite passed all 3,741 cases in 258.42 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
4.53 seconds with 100% statement and branch coverage. All four parents exited zero. Both core legs
passed conditional accounting, including the actual filesystem-root case. The default provider-live
component was not requested; this gate makes no physical-provider claim.
The final audit at 04:38:35 UTC matches all 871 native/snapshot Haskell files, the package description,
894 untouched files, thirteen metadata/Python snapshots and all 602 compiler fixtures. All three targets
retain saved bytes and hashes, old paths are absent, and the consumers still differ only in their three
actual Mode-home paths. No test or probe children survive. The canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 04:38:26 UTC, exit zero
in 0.184419897 seconds with empty stderr.

The post-closure documentation check passed all 17 cases in 3.93 seconds on 2026-11-01 at
04:39:09-04:39:17 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next cohort began.

#### Remaining Work

None.

### Sprint 13.15: Private implementation source homes, cohort 12 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Lifecycle.Plan`, `HostBootstrap.Lifecycle.Prepared`, `HostBootstrap.Lifecycle.Prepared.Internal`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Lifecycle.Plan` | 113,963 | 2,652 | `88d4b886b0a8efef5ce8886999b3495c9124c5a377aa20dea2f2807ff895e187` |
| `HostBootstrap.Lifecycle.Prepared` | 6,912 | 184 | `7c6b1d043b0e4e37772c051bf43c458687d823cfc3e40111136bbcf236a48a64` |
| `HostBootstrap.Lifecycle.Prepared.Internal` | 16,747 | 426 | `783a31e3355577515025c2d239657ec8b80da773606d4e7dfea17abf53f09bbf` |

This is three source-module relocations and zero changed Haskell content lines, totaling 137,622 bytes
and 3,262 physical lines. The only consumer edit replaces the two independent Plan and Prepared.Internal
homes in `ProjectPlanSpec`, measuring four changed nonempty lines (four physical). An exact replacement
comparison preserves every other byte of that consumer. Fourteen captured metadata/control texts and
895 other source byte lengths and hashes match the baseline, including all Authority and Handoff arrays,
roles, prepared-entry checks, fence and producer policies, shared snapshot identities and frozen subjects.
Cabal, Main's three roots, fourteen library roots, DATA identities and every Python input remain unchanged.
Current governed paths follow the actual homes. No Done deferred phase's covered inputs change.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
4.007 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Actual installed metadata retains
Plan and Prepared.Internal hidden uniquely in Main, with Prepared uniquely Main-exposed. Fourteen local
units remain and no handoff implementation unit exists. The warm build reported library and executable
preprocessing/building with no individual compilation lines; it makes no fresh body-compilation claim.

The initial Linux synchronization launch on 2026-11-01 at 04:41:16 UTC failed with
`WSL_E_DISTRO_NOT_FOUND`, exit minus one, before the Linux script entered: no snapshot mutation or test
ran. Read-only checks confirmed the exact registered distro and retained running container; explicit
argument calls and the same wrapper then succeeded. The cause of the transient launch failure is unproven.
No restart or recreation occurred. Synchronization succeeded at 04:43:12-04:43:18 UTC with parent exit
zero, preserving the existing source and Cabal-cache mounts before the actual full gate began.

The full four-command Linux gate passed on 2026-11-01 at 04:43:39-04:48:18 UTC on the retained
infrastructure with GHC 9.12.4 and Cabal 3.16.1.0. Standalone core passed all 3,741 cases in
255.61 seconds. The demo passed its own 165 cases in 1.35 seconds and its included core suite passed
all 3,741 cases in 257.04 seconds. Both Cabal parents reported explicit completion and PASS. Python
checks passed; all 376 unfiltered tests passed in 4.40 seconds with 100% statement and branch coverage.
All four parents exited zero. Both core legs passed conditional accounting, including the actual
filesystem-root case. The default provider-live component was not requested; this gate makes no
physical-provider claim. The initial WSL synchronization launch failure above preceded the actual gate.

The final audit matches all 871 native/snapshot Haskell files, the package description, 895 untouched
files, fourteen metadata/Python snapshots and all 602 compiler fixtures. All three targets retain their
saved bytes and hashes, old paths are absent, and ProjectPlanSpec still changes only its two independent
physical homes. The final process audit at 04:48:57 UTC found no surviving test or probe children and
confirmed the existing container remained unrestarted. The canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 04:48:47-04:48:48 UTC,
exit zero in 0.181521936 seconds.

The post-closure documentation check passed all 17 cases in 4.25 seconds on 2026-11-01 at
04:51:41-04:51:50 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next cohort began.

#### Remaining Work

None.

### Sprint 13.16: Private implementation source homes, cohort 13 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Recovery.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Lifecycle.Recovery`, `HostBootstrap.Lifecycle.ResourceRecord`, `HostBootstrap.Lifecycle.Rooted`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Recovery.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Recovery.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/ResourceRecord.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Lifecycle.Recovery` | 13,798 | 307 | `4d0bda0ea87a373d6271f0694d8f3e5454188a0abb8034f4137c88d8f68ba9d9` |
| `HostBootstrap.Lifecycle.ResourceRecord` | 19,551 | 423 | `670e1afc6bb6fecaa141a1b541d9b4cb09dcb1cf11a6aee3790835015e83ceb0` |
| `HostBootstrap.Lifecycle.Rooted` | 38,266 | 827 | `53bfd1a16ff3ef9e5c6c25b4c3ad0e801ab8ec0502560540925cb03e12f07400` |

This is three source-module relocations and zero changed Haskell content lines, totaling 71,615 bytes
and 1,557 physical lines. Consumer edits measure 26 changed nonempty lines (26 physical): 24 in
`HandoffSpec` and two in `ProjectPlanSpec`. Twelve Lifecycle.Rooted path replacements affect twelve
Handoff ownership arrays; ten require sorted reordering and two retain their order. Exact member
multiplicities and every character outside those arrays remain unchanged. ProjectPlanSpec changes only
its independent Rooted home. All 64-hex multiplicities, 153 ordered requirements, raw response and Relay
slices, 26 ordinary readers and the separate Handoff.Rooted freezes remain exact. Seventeen captured
metadata/control texts and 894 other source byte lengths and hashes match the baseline. Cabal, Main's
three roots, fourteen library roots, DATA identities and every Python input remain unchanged. Current
governed paths follow the actual homes. No Done deferred phase's covered inputs change.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
3.773 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Actual installed metadata retains
Recovery, ResourceRecord and Lifecycle.Rooted hidden uniquely in Main. Fourteen local units remain and
no handoff implementation unit exists. This warm build reported library and executable
preprocessing/building with no individual compilation lines; it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 04:55:30-05:00:41 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 272.40 seconds. The demo passed its own 165
cases in 1.57 seconds and its included core suite passed all 3,741 cases in 272.37 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
4.46 seconds with 100% statement and branch coverage. All four parents exited zero. Both core legs
passed conditional accounting, including the actual filesystem-root case. The default provider-live
component was not requested; this gate makes no physical-provider claim.

The final audit matches all 871 native/snapshot Haskell files, the package description, 894 untouched
files, seventeen metadata/Python snapshots and all 602 compiler fixtures. All three targets retain saved
bytes and hashes, and old paths are absent. The repeated ownership-array audit confirms only the twelve
expected substitutions and ten sorted reorderings, with exact members, multiplicities and outside text;
every frozen subject remains unchanged. ProjectPlanSpec still changes only its one independent Rooted home.
The final process audit at 05:00:59 UTC found no surviving test or probe children and confirmed the existing
container remained unrestarted. The canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 05:00:52 UTC, exit zero
in 0.190425581 seconds.

The post-closure documentation check passed all 17 cases in 3.88 seconds on 2026-11-01 at
05:01:35-05:01:43 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next cohort began.

#### Remaining Work

None.

### Sprint 13.17: Private implementation source homes, cohort 14 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Lifecycle.Rooted.Receipt`, `HostBootstrap.Lifecycle.RootedPlan`, `HostBootstrap.Lifecycle.Session`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Receipt.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/RootedPlan.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Lifecycle.Rooted.Receipt` | 13,542 | 292 | `5e02b5421c3cdb55c69e0eff1dc69bea266baa8ae364be483231116d63ffc36e` |
| `HostBootstrap.Lifecycle.RootedPlan` | 24,631 | 567 | `6f38f4a0c3656f3f229ba6f8302e025378a84041b286f26d98a2bb8e80cd17f2` |
| `HostBootstrap.Lifecycle.Session` | 212,434 | 4,561 | `9534227bf424e3f07488b55cff75b0ca80af60bf74758e10f9e78416ef2dd049` |

This is three source-module relocations and zero changed Haskell content lines, totaling 250,607 bytes
and 5,420 physical lines. Consumer edits measure 36 changed nonempty lines (36 physical): 26 in
`HandoffSpec`, four in `AuthoritySpec` and six in `ProjectPlanSpec`. Thirteen Receipt path substitutions
require thirteen sorted ownership-array reorderings, with exact members, multiplicities and all outside
text preserved. Authority changes only its two actual RootedPlan/Session homes; ProjectPlan changes only
its three independent homes. All 64-hex multiplicities, 153 ordered requirements, raw response and Relay
slices, 26 ordinary readers and frozen subjects remain exact. Eighteen captured metadata/control texts
and 893 other source byte lengths and hashes match the baseline, explicitly including the original
Session.Testing and Transaction source bodies and DATA metadata. Their source homes remain under `src`.
Cabal, Main's three roots, fourteen library roots, DATA identities and every Python input remain unchanged.
Current governed paths follow the actual homes. No Done deferred phase's covered inputs change.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
4.111 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Actual installed metadata retains
Receipt and RootedPlan hidden uniquely in Main, with Session uniquely Main-exposed. Fourteen local units
remain and no handoff implementation unit exists. No individual compilation lines were reported;
this warm build provides ownership evidence and makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 05:04:33-05:09:46 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 256.03 seconds. The demo passed its own 165
cases in 1.46 seconds and its included core suite passed all 3,741 cases in 255.80 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
4.30 seconds with 100% statement and branch coverage. All four parents exited zero. Both core legs
passed conditional accounting, including the actual filesystem-root case. The default provider-live
component was not requested; this gate makes no physical-provider claim.

The final audit matches all 871 native/snapshot Haskell files, the package description, 893 untouched
files, eighteen metadata/Python snapshots and all 602 compiler fixtures. All three targets retain saved
bytes and hashes, old paths are absent, and the original Session.Testing/Transaction bodies and DATA
metadata remain exact. The repeated ownership-array audit confirms thirteen substitutions and sorted
reorderings with exact members, multiplicities, outside text and frozen subjects. Authority and ProjectPlan
remain their exact expected-home-only transforms. The final process audit at 05:10:02-05:10:03 UTC found
no surviving test or probe children and confirmed the existing container remained unrestarted. The
canonical compiled Python covers digest remains
`43460ba7dd0f5e74500d3c40fdc1784031a67dccf7a60f1a86b66c01c109bfb3` at 05:09:54-05:09:55 UTC,
exit zero in 0.186879665 seconds.

The post-closure documentation check passed all 17 cases in 3.89 seconds on 2026-11-01 at
05:10:28-05:10:36 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next cohort began.

#### Remaining Work

None.

### Sprint 13.18: Private implementation source homes, cohort 15 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Transaction.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`tests/test_packaging.py`
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Lifecycle.Transaction`, `HostBootstrap.Lift.Context`, `HostBootstrap.ProjectPlan`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Transaction.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lift/Context.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- The existing `lifecycle-transaction-internal` DATA library retains `src` for `Lifecycle.Session.Testing`
  and adds the new root for `Lifecycle.Transaction`. Its existing separate DATA identity and hidden transaction
  export rule remain unchanged; this creates no third copy.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Lifecycle.Transaction` | 38,356 | 838 | `cdca95755ef3def551c735051a5caf63764e8510ec0bdff0518f87c67b509118` |
| `HostBootstrap.Lift.Context` | 8,938 | 272 | `b91df54a602d9693a0f17a5dc5228548c1d5d4952f3e1a17c89d90687ff28ac3` |
| `HostBootstrap.ProjectPlan` | 17,391 | 495 | `3624e8c494e4f2d65a77b12559a6f82d6ef631efa69c8a84cc0eee2754109dd9` |

This is three source-module relocations and zero changed Haskell content lines, totaling 64,685 bytes
and 1,605 physical lines. Final consumer edits measure 42 changed nonempty lines (43 physical): two in
ProjectPlanSpec, two in Cabal metadata, six in ChainSpec, 26 (27 physical) in ProviderBackendSpec, and six
in the Python packaging test. The existing transaction DATA library's source directories are
`src, internal/handoff-implementation`; `src` remains required for Session.Testing. Exact whole-description
and DATA-stanza comparisons preserve its identity, private visibility, sole Session.Testing exposure,
hidden Transaction, dependencies and core-test dependency. Main retains its own hidden Transaction and
no dependency on the DATA unit: the two audited compiled identities share one physical source, with no
third copy. Session.Testing's source body and expected home remain unchanged.
ChainSpec resolves ProjectPlan through the existing package metadata reader; its other helpers and all
source-shape assertions remain unchanged. ProviderBackendSpec's whole-production absence policy reads
all actual library sources through the existing shared inventory. The Python provider census includes
physical `core/hostbootstrap-core/src`, `core/hostbootstrap-core/internal`, and `demo/src` sources. Its AST differs only in that source assignment;
all forbidden-name, caller-use and parser controls remain unchanged. External addenda retain each original
baseline-matching before text and exact reader-only diff. Fourteen captured metadata/control texts and
892 other source byte lengths and hashes match the baseline after excluding these three authorized test
adoptions. The original baseline is unchanged. The dependency DATA root, Main's three roots, fourteen
library roots and Python runtime remain unchanged. Governed paths and the transaction DATA source-directory
cell follow the actual homes. The covered Python test edit expires the Python-floor evidence; its own
quality sprint renews the gate and canonical covers digest before this sprint resumes validation.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
25.353 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Cabal reconfigured its existing
components after the DATA source-root change. Actual installed metadata retains Transaction hidden in
exactly the existing Main and transaction DATA identities; Session.Testing is exposed only by the DATA
unit. Lift.Context and ProjectPlan remain uniquely Main-exposed, and Main does not depend on the transaction
DATA unit. Fourteen local units remain and no handoff implementation unit exists. The warm build reported
preprocessing/building with no individual compilation lines; it makes no fresh body-compilation claim.

The initial full four-command gate ran on 2026-11-01 at 05:13:37-05:18:30 UTC. Both core legs
failed the same single case out of 3,741: ChainSpec's "planned observations remain indexed from action
through settlement" still opened ProjectPlan through a fixed `src` reader. Standalone core reported
one failure in 248.82 seconds, Cabal FAIL and parent exit one; the demo-included core reported one failure
in 246.32 seconds, Cabal FAIL and parent exit one. The demo's own 165 cases passed in 1.33 seconds.
Python checks passed and all 376 unfiltered tests passed in 4.23 seconds with 100% statement and branch
coverage. These are the initial failed gate results; the sprint remains Active pending the reader adoption
and a complete passing rerun. Production module bytes and the DATA-unit change remain their measured
baseline-preserving edits.

The corrected frozen tree passed the focused selection on 2026-11-01 at 05:31:22-05:31:42 UTC:
all 19 cases passed in 4.68 seconds, with explicit Cabal PASS and parent exit zero. The actual selected
subjects are ChainSpec's planned-observation guard, ProviderBackendSpec's one-interpreter guard, and all
17 DocValidator cases. Both changed Haskell specs compiled cleanly under the default warnings policy.
The re-audit matches all 871 native/snapshot Haskell files, 892 untouched saved sources, fourteen
metadata snapshots, all 602 compiler fixtures and the three exact addendum after hashes. The covered
Python-floor gate and current `0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`
evidence are reclosed and current before the complete four-command rerun.

The corrected full four-command gate passed on 2026-11-01 at 05:31:59-05:36:16 UTC with GHC 9.12.4
and Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 243.46 seconds; the demo passed its own
165 cases in 1.49 seconds and its included core suite passed all 3,741 cases in 243.30 seconds. Both
Cabal parents reported explicit completion and PASS. Fresh Python checks passed; all 376 unfiltered tests
passed in 5.85 seconds with 100% statement and branch coverage. All four parents exited zero. Both core
legs passed conditional accounting, including actual filesystem-root accounting. The default provider-live
component was not requested; this gate makes no physical-provider claim. The initial failed full gate remains
recorded separately above.
Final audits match all 871 native/snapshot Haskell files, the package description, all 602 compiler
fixtures, fourteen metadata snapshots, 892 untouched original sources and each of the three controlled
consumer addenda. The original three moved modules retain saved bytes and hashes with old paths absent;
the exact DATA-stanza transform, independent ProjectPlan home and existing identities remain intact.
The canonical compiled covers digest at 05:36:27 UTC is the current Python-floor value
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`, exit zero in 0.210492505
seconds. Its header and README status are Done with one current evidence field. The process audit at
05:36:34-05:36:35 UTC found no surviving test or probe children and confirmed the retained container
remained unrestarted.

The final closure check passed all 17 DocValidator cases in 4.22 seconds on 2026-11-01 at
05:37:33-05:37:41 UTC, with Cabal PASS and parent exit zero. All 95 governed documents, including the
renewed Python-floor evidence and reviewed plan refinements, were synchronized and byte-verified before
the next source cohort began.

#### Remaining Work

None.

### Sprint 13.19: Private implementation source homes, cohort 16 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Frame.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Projection/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.ProjectPlan.Construct.Internal`, `HostBootstrap.ProjectPlan.Frame`, `HostBootstrap.ProjectPlan.Projection.Internal`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Construct/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Frame.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Frame.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Projection/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Projection/Internal.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline and its immutable control addendum on 2026-11-01 verify the three
source/target pairs retain identical raw bytes and SHA-256; each old path is absent and each original
declaration has one physical home. The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.ProjectPlan.Construct.Internal` | 8,507 | 259 | `821e9b1deb79a23ae62339022d86aee874a0a1f3e02bf4f91204ae596d9cadb3` |
| `HostBootstrap.ProjectPlan.Frame` | 6,510 | 167 | `70da23e62fc6b42e19059e9cb4fdd36df10def3b7513995c024bf499d9a235bb` |
| `HostBootstrap.ProjectPlan.Projection.Internal` | 15,982 | 319 | `252742d3ba09fa228f8ddc17ab7c1a099cc2bd0810a8aab0a1bfc2ccd9e17c8a` |

This is three source-module relocations and zero changed Haskell content lines, totaling 30,999 bytes
and 745 physical lines. The only consumer edit changes three independent expected homes in
ProjectPlanSpec, measuring six changed nonempty lines (six physical), with all outside text unchanged.
The original cohort baseline remains immutable; its separate control addendum verifies the three
reader/census before hashes and their reviewed current after hashes. All fourteen metadata snapshots,
892 other original source byte lengths and hashes, and those three updated control files match. Every
Handoff array, frozen subject, source/role/producer policy, DATA identity, package-description field and
Python input remains unchanged. Main's three roots and the fourteen library roots retain their actual
scope; current governed paths follow the physical homes. No Done deferred evidence expires.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
3.370 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Actual installed metadata retains
Frame uniquely Main-exposed, with Construct.Internal and Projection.Internal uniquely Main-hidden.
Fourteen local units remain and no handoff implementation unit exists. The warm build reported library
and executable preprocessing/building with no individual compilation lines; it makes no fresh
body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 05:40:21-05:45:04 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 258.59 seconds. The demo passed its own 165
cases in 1.52 seconds and its included core suite passed all 3,741 cases in 258.45 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
5.67 seconds with 100% statement and branch coverage. All four parents exited zero. Both core legs
passed conditional accounting, including actual filesystem-root accounting. The default provider-live
component was not requested; this gate makes no physical-provider claim.

Final audits match all 871 native/snapshot Haskell files, the package description and all 602
compiler fixtures. Each target retains saved bytes and SHA-256 with its old path absent. The immutable
control addendum matches all three original baseline hashes to their captured before texts and accepted
current after hashes; 892 other source hashes and fourteen metadata snapshots remain unchanged.
ProjectPlanSpec still differs only in its three independent physical homes. Every Handoff, Python and
DATA subject remains frozen. The canonical compiled covers digest at 05:45:16-05:45:17 UTC remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`, exit zero in 0.187433599
seconds, matching the one current Python-floor evidence field. The process audit at 05:45:25 UTC found
no surviving test or probe children and confirmed the retained container remained unrestarted.

The closure check passed all 17 DocValidator cases in 4.17 seconds on 2026-11-01 at
05:45:54-05:46:03 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next source cohort began.

#### Remaining Work

None.

### Sprint 13.20: Private implementation source homes, cohort 17 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectRoot.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.ProjectRoot`, `HostBootstrap.RoleLifecycle`, `HostBootstrap.Service`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/ProjectRoot.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectRoot.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/RoleLifecycle.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Service.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.ProjectRoot` | 6,342 | 144 | `2d7ed3ddeca964b58d32db5fba34b994a202977d0f4c04eb9d653810c309f445` |
| `HostBootstrap.RoleLifecycle` | 62,541 | 1,345 | `166071b424b8daeb727bf417b5155247dde87d599c89acbca42bb143e3df180a` |
| `HostBootstrap.Service` | 37,416 | 829 | `3a518ce9f7d0b8fc8ee5b33649011033414047698697502159fded7c5e0cf6cf` |

This is three source-module relocations and zero changed Haskell content lines, totaling 106,299 bytes
and 2,318 physical lines. The only consumer edit replaces one independently expected Service home in
SpecIndexSpec, measuring two changed nonempty lines (two physical), with every outside character
unchanged. All fourteen metadata snapshots and 895 other source byte lengths and hashes match the
current baseline, including the corrected Chain, Provider and Python controls. Every Handoff array,
source/role/producer policy and frozen subject remains unchanged. The package description, DATA
identities, Main's three roots, fourteen library roots and Python input tree remain exact.
Current governed paths follow the physical homes. The already Active service-runtime phase's exact
Service.hs and RoleLifecycle.hs covers follow these files without a renewed completion claim; its Service
directory cover remains under `src` while the directory's other modules remain there. No Done deferred
phase's covered inputs change.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
4.077 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Actual installed metadata retains
ProjectRoot, RoleLifecycle and Service uniquely exposed by Main. Fourteen local units remain and no
handoff implementation unit exists. The warm build reported library and executable preprocessing/building
with no individual compilation lines; it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 05:48:42-05:53:02 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 249.07 seconds. The demo passed its own 165
cases in 1.61 seconds and its included core suite passed all 3,741 cases in 248.35 seconds. Both Cabal
parents reported explicit completion and PASS with parent exit zero. Python checks exited zero in
0.7550837 seconds; all 376 unfiltered tests passed in 5.81 seconds with 100% statement and branch
coverage and parent exit zero. Both core legs passed conditional accounting, including actual
filesystem-root accounting. The default provider-live component was not requested; no physical-provider
claim is made.
Reporting was interrupted before the post-gate audits. The retained completed harness sessions were
recovered without restarting or rerunning a gate command; their captured completion markers and final
parent exits establish these results. Actual post-gate audits ran at 19:29:37-19:30:00 UTC and passed:
all 871 native/snapshot Haskell files, the package description, 895 current source controls, fourteen
metadata snapshots and all 602 compiler fixtures match. Each moved target retains saved bytes and SHA-256
with its old path absent; SpecIndex remains its sole Service-home substitution with exact outside text.
The canonical compiled covers digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`, parent exit zero with a
0.463321693-second measurement, matching the one current Python-floor evidence field. The process and
mount audit found no surviving test or probe children and confirmed the retained container's unchanged
start time, init setting and source/cache mounts. The Active service-runtime covers follow the exact
moved files; no completion evidence for that phase is renewed here.

The closure check passed all 17 DocValidator cases in 4.26 seconds on 2026-11-01 at
19:31:24-19:31:33 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the next source cohort began.

#### Remaining Work

None.

### Sprint 13.21: Private implementation source homes, cohort 18 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service/Program.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Service.Internal`, `HostBootstrap.Service.Program`, `HostBootstrap.Step`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Service/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service/Internal.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Service/Program.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service/Program.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Step.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Service.Internal` | 5,697 | 139 | `672e0725830f4bb5198cd957499fcae1d3355a4065282adf35999e349f461612` |
| `HostBootstrap.Service.Program` | 18,123 | 447 | `49e2a5ee35f44fee6dcea48d00ac2928a1bfd1e2ac7184542f7bd8e6332754da` |
| `HostBootstrap.Step` | 44,228 | 1,082 | `b6a32faae5d0626a9582600415131c7e2aac77d0cfca6880e4c0656ddf47397a` |

This is three source-module relocations and zero changed Haskell content lines, totaling 68,048 bytes
and 1,668 physical lines. Consumer edits measure six changed nonempty lines (six physical): two actual
Service.Internal home substitutions in SpecIndexSpec and one independent Step home in ProjectPlanSpec.
Every outside character is unchanged. All thirteen metadata snapshots and 894 other source byte lengths
and hashes match the current baseline, including the corrected reader/census controls. Cabal, Main's
three roots, fourteen library roots, DATA identities, Python inputs and all frozen subjects remain exact.
Current governed paths follow the actual homes. The already Active service-runtime phase's Service
directory cover follows its relocated children, without a renewed completion claim. No Done deferred
phase's covered inputs change.
On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
7.465 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Installed metadata retains
Service.Internal uniquely Main-hidden and Service.Program/Step uniquely Main-exposed. Fourteen local
units remain, with no handoff implementation unit. The warm build reported library/executable
preprocessing and building without individual compilation lines; it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 19:36:23-19:41:14 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 264.33 seconds. The demo passed its own 165
cases in 1.51 seconds and its included core suite passed all 3,741 cases in 263.66 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
5.96 seconds with 100% statement and branch coverage. All four parents exited zero. Both core legs
passed conditional accounting, including actual filesystem-root accounting. The default provider-live
component was not requested; this gate makes no physical-provider claim.

Final audits at 19:41:26-19:41:35 UTC match all 871 native/snapshot Haskell files, the package
description, 894 current source controls, thirteen metadata snapshots and all 602 compiler fixtures.
Each target retains saved bytes and SHA-256 with its old path absent; both consumers remain their exact
expected-home-only transforms. Every Handoff, DATA, Python and frozen policy subject remains unchanged.
The canonical compiled covers digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`, parent exit zero with a
0.199240577-second measurement, matching the one current Python-floor evidence field. The process audit
found no surviving test or probe children and confirmed the retained container, init and mounts were
unchanged. The Active service-runtime directory cover follows the actual moved files without a renewed
completion claim.

The closure check passed all 17 DocValidator cases in 4.17 seconds on 2026-11-01 at
19:42:29-19:42:37 UTC, with Cabal PASS and parent exit zero. All 95 governed documents were synchronized
and byte-verified before the final source relocation cohort began.

#### Remaining Work

None.

### Sprint 13.22: Private implementation source homes, cohort 19 [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, affected source-ownership specs
**Production budget**: three byte-identical source-file relocations, zero changed Haskell content lines;
no declaration moves or body edits
**Substrates**: linux-cpu
**Docs to update**: current governed source-path references for the three named modules

#### Objective

Give `HostBootstrap.Substrate`, `HostBootstrap.Teardown`, `HostBootstrap.Teardown.Internal`
one physical home under `internal/handoff-implementation`, with Main retaining their sole production
compiler ownership and all existing public and hidden module registrations.

#### Deliverables

- `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Substrate.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs` with byte-identical contents.
- `core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs` has its single physical home at
  `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs` with byte-identical contents.
- Independent expected physical paths, current implementation links and ledger paths follow these three
  modules. Existing byte/token freezes, caller sets, authority roles and public exports remain unchanged.
- Main consumes each file once in its existing unit. The current DATA exceptions retain only their
  already-audited identities; no implementation is copied and no new test import is exposed.

#### Validation

Measure each source/target pair before and after the move: identical byte length and SHA-256, no remaining
old file, one actual declaration, and the intended Main component registration. Record all three path pairs
and zero changed content lines. Existing source-ownership, Handoff, indexed project-plan, sealed-export,
public compiler and DocValidator cases run through all four host static commands; record their actual counts
and parent exits before proceeding to the next cohort.

The saved cohort baseline on 2026-11-01 verifies the three source/target pairs retain identical raw
bytes and SHA-256; each old path is absent and each original declaration has one physical home.
The deliverables above identify the measured pairs.

| Module | Bytes | Physical lines | SHA-256 before and after |
|--------|------:|---------------:|-------------------------|
| `HostBootstrap.Substrate` | 11,879 | 313 | `76091fbdfdcba70863e09f8c4aa25401cb511906cc5fc8a164f436435f1b9986` |
| `HostBootstrap.Teardown` | 58,443 | 1,381 | `3e231ef75f84d19f37e868b20f62b84bef10b8dd7964b092b222bdef934b4c53` |
| `HostBootstrap.Teardown.Internal` | 66,649 | 1,235 | `8d2d97466b05468ddc4826876a8adc1fdb2ae8886e83412f7a7facb28d0301c5` |

This is three source-module relocations and zero changed Haskell content lines, totaling 136,971 bytes
and 2,929 physical lines. Consumer edits measure 52 changed nonempty lines (52 physical): 46 in
HandoffSpec, two in AuthoritySpec and four in ProjectPlanSpec. Nineteen path substitutions affect eighteen
Handoff ownership arrays; thirteen use their reviewed sorted reorderings and five keep their original
order. Every member multiset and all outside text remain exact. Authority and ProjectPlan are their
independent expected-home-only transforms. All 26 frozen SHA-literal occurrences, 153 ordered
requirements, the 6,323-byte response-authentication subject, three Relay sections and their concatenated
digest, and thirteen ordinary readers totaling 26 nonempty lines remain exact. All twelve metadata
snapshots and 893 other current source byte lengths and hashes match. Cabal, Main's three roots,
fourteen library roots, DATA identities, Python inputs and all independent policies remain unchanged.
Current governed paths follow the physical homes. No Done deferred phase's covered inputs change;
private-unit registration remains its own separately validated sprint.

On 2026-11-01, native Windows `cabal build all` from `core/` passed with parent exit zero in
3.607 seconds under GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. Installed metadata retains
Substrate and Teardown uniquely Main-exposed and Teardown.Internal uniquely Main-hidden. Fourteen local
units remain, with no handoff implementation unit. The warm build reported library/executable
preprocessing and building without individual compilation lines; it makes no fresh body-compilation claim.

The full four-command Linux gate passed on 2026-11-01 at 19:47:32-19:52:44 UTC with GHC 9.12.4 and
Cabal 3.16.1.0. Standalone core passed all 3,741 cases in 253.82 seconds. The demo passed its own 165
cases in 1.54 seconds and its included core suite passed all 3,741 cases in 255.80 seconds. Both Cabal
parents reported explicit completion and PASS. Python checks passed; all 376 unfiltered tests passed in
5.75 seconds with 100% statement and branch coverage. All four parents exited zero. Both core legs
passed conditional accounting, including actual filesystem-root accounting. The default provider-live
component was not requested; no physical-provider claim is made.
Final audits at 19:52:57-19:53:05 UTC match all 871 native/snapshot Haskell files, the package
description, 893 current controls, twelve metadata snapshots and all 602 compiler fixtures. Each target
retains saved bytes and SHA-256 with its old path absent. The repeated array audit confirms all eighteen
ownership arrays, nineteen substitutions and thirteen reviewed sorted reorderings, with exact member
multisets and outside text. All frozen hashes, ordered requirements, raw response/Relay sections and
ordinary readers remain unchanged. The canonical compiled covers digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`, parent exit zero with a
0.182727295-second measurement, matching the one current Python-floor evidence field. The process audit
found no surviving test or probe children and confirmed the retained container, init and mounts were
unchanged.
The complete relocation census independently matches all 57 targets to their original nineteen cohort
baselines: 2,174,191 bytes and 48,649 physical LF lines, with every old path absent and each declaration
having one physical home. Their production compiler ownership remains Main until the separately gated
private-unit registration; the two existing DATA exceptions retain only their audited identities.

#### Remaining Work

None.

### Sprint 13.23: Handoff tests share the real private implementation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`,
`core/hostbootstrap-core/test/SpecIndexSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/`, `core/cabal.project`, `demo/cabal.project`
**Source ownership scope**: the 57 byte-identical modules relocated by Sprints 13.4 through 13.22
**Production budget**: no planned production Haskell edits or file relocations; any necessary source change
is limited to 400 changed nonempty lines across three modules and is recut before implementation if it cannot fit
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/unrepresentable_state.md`, `documents/engineering/testing.md`,
`documents/engineering/cabal_layout.md`, `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Let core tests exercise the actual hidden handoff implementations while Main and tests use the same
compiled identities, preserving the consumer facade and every private authority boundary.

#### Objective boundary

The current lexical-import audit finds a forward closure of 57 Main source modules, containing 29 public
and 28 hidden modules. Forward closure alone does not supply the package cut: 23 remaining Main modules have 61
imports of 19 hidden members of that closure, beyond the four intended test owners. A private unit exposing
only the former public modules and those four owners would leave those Main imports unavailable. Expanding
the source cut until both directions close without selective visibility reaches 138 of Main's 149 source
modules; that is not the proposed bounded ownership change.

The `library handoff-implementation-internal` route retains the 57-module cut, gives Main its
required private imports, and limits the test component independently through Cabal module thinning. It also
uses disjoint home-source roots. Leaving the
same 57 files discoverable under Main's `hs-source-dirs` would let its home-module search compile them again
instead of consuming the private unit. Physical relocation of the existing files, not a second copy, supplies
that separation. Cabal's [source-directory rule](https://cabal.readthedocs.io/en/stable/cabal-package-description-file.html#pkg-field-hs-source-dirs)
and [mixin visibility rule](https://cabal.readthedocs.io/en/stable/cabal-package-description-file.html#pkg-field-mixins)
describe these constraints; the actual build and compiler controls below verify the implementation.

[Sprint-size requirements](development_plan_standards.md#g-phase-and-sprint-document-requirements)
apply to the source moves as well as the registration. Sprint 13.3 adopts the source readers, and Sprints
13.4 through 13.22 each relocate exactly three module files while Main remains their production owner.
Each physical move counts as one source module and changes zero Haskell content lines only when its saved
and final bytes are identical. Moving declarations or reindenting their bodies counts both removed and added
lines and is outside these relocation sprints. The 57 files total 2,174,191 bytes and 48,649 physical lines;
their sizes are measured scope, not new implementation. Each bounded cohort closes its own full gate.
This registration sprint starts only with the completed disjoint source root, and performs no further
production file relocation or body change.

#### Registration scope

All names below carry the `HostBootstrap.` prefix. The current 29 public members are `Activation`,
`Authority`, `Config.Class`, `Config.Fields`, `Config.Schema`, `Config.Vocab`, `Context`, `Dhall.Gen`,
`Dhall.Hoist`, `Handoff`, `Harness`, `HostConfig`, `HostTool`, `Lifecycle.Closure`, `Lifecycle.Context`,
`Lifecycle.Execution`, `Lifecycle.Mode`, `Lifecycle.Prepared`, `Lifecycle.Session`, `Lift.Context`,
`ProjectPlan`, `ProjectPlan.Frame`, `ProjectRoot`, `RoleLifecycle`, `Service`, `Service.Program`, `Step`,
`Substrate`, and `Teardown`.

The four intended newly test-visible members are `Handoff.Protocol`, `Handoff.Receiver`, `Handoff.Relay`, and
`Handoff.Internal`. The additional 19 members required by remaining Main callers are
`Config.Authority.Internal`, `Config.Install.Native`, `Config.Schema.Internal`, `Handoff.Receiver.Internal`,
`Handoff.Recovery`, `Handoff.Rooted`, `Handoff.Runtime`, `Lifecycle.Context.Internal`,
`Lifecycle.Dependency.Internal`, `Lifecycle.Execution.Internal`, `Lifecycle.Plan`,
`Lifecycle.Prepared.Internal`, `Lifecycle.ResourceRecord`, `Lifecycle.Rooted`, `Lifecycle.Rooted.Receipt`,
`Lifecycle.RootedPlan`, `ProjectPlan.Construct.Internal`, `ProjectPlan.Projection.Internal`, and
`Teardown.Internal`.

Those groups give the private unit 52 exposed members for its trusted component consumers.
Its five remaining `other-modules` are `Config.Class.Internal`, `Config.Fields.Internal`,
`Lifecycle.Recovery`, `Lifecycle.Transaction`, and `Service.Internal`. Main reexports only the former 29
public members, alongside its unchanged other public surface. The core-test dependency selects only the
four intended hidden owners through an explicit mixin module list; it obtains the public members through
Main. The 19 Main-needed members are not thereby test-visible. Their source imports, the actual per-component
module maps, and the absence of any second unthinned package exposure are checked by the actual
compiler controls below.

The existing `lifecycle-transaction-internal` DATA fixture and `lifecycle-dependency-internal` DATA unit
already compile their own distinct transaction/dependency implementations. Preserve those audited routes
and their independent role controls while updating source locations; do not introduce another copy or
substitute their identities for the production implementations. In particular, test privacy checks identify
the new implementation unit's modules, rather than mistaking an already available same-name DATA module for
new access to a production identity.

#### Deliverables

- Register one dependency-closed private implementation unit rather than copying the four owners into a
  test component. Recompute both import directions over the named 57-module scope before editing: the
  private unit imports no remaining Main source, and every remaining Main import reaches an actually
  exposed private-unit member. Protocol imports Handoff, Receiver imports Handoff/Authority, and Relay
  imports activation and lifecycle owners, so a four-module extraction is not dependency-safe.
- Register the 57 unchanged implementations in their completed disjoint private source root. Main consumes
  those compiled modules and reexports exactly its former public surface. No moved source remains on Main's
  home search path; there are no copied Main identities, duplicated authority definitions, injected
  callbacks/selectors, new authority helpers, or constructor/test-only minting route.
- The private unit exposes the former 29 public members, four intended test owners, and 19
  additional Main-needed members, retaining five other modules privately. Main reexports only its former
  public members; its access to the 19 additional members creates no public facade route.
- The only newly test-exposed hidden owners are `Handoff.Protocol`, `Handoff.Receiver`, `Handoff.Relay`, and
  `Handoff.Internal`. Main never reexports them; `hostbootstrap-core-test` depends on the same private unit.
  An explicit four-module mixin list thins that test dependency, with no second unthinned exposure. The
  remaining hidden modules retain their test and consumer privacy, and no consumer package gains a new
  import route.
- Adopt Main exposed/reexported/other-module expectations, unique source ownership, component dependencies,
  disjoint source scans, and public-export readers coherently. Keep the existing 73 literal export pins and
  unchanged sealed-input policy; review the additional 24 required facade export lists, giving 97 required
  entries with no stale entry in the measured final graph. Preserve all existing lower private-unit ownership
  and independent role, origin, and representation controls.
- Re-measure every affected official Main-only compiler subject and exact unit-qualified diagnostic, keeping
  named refusal categories instead of accepting a broad missing-import result. Same-file positives with
  exactly the core-test thinned module exposure establish the genuine test route and shared identities;
  negative controls refuse the 18 non-colliding Main-only module imports in that same context. Inspect
  the actual compiler module map for all 19 production implementation identities: their private-unit
  origins have neither a package-flag exposure nor a Main reexport, while the four intended test owners
  have the actual selected exposure. A separate typed identity refusal distinguishes the already exposed
  same-name dependency DATA module from the production dependency implementation; an unqualified import
  of that DATA module is not a privacy failure. No unknown package qualifier is accepted as proof.
- Replace HandoffSpec's blanket runtime-test import blacklist with the exact allowed core-test component
  rule. Later hidden-kernel tests use this route; exposing `Handoff.Rooted` for its coordinate tests remains
  Sprint 13.42's separate adoption, and no real recursive child/process success is claimed here.

#### Validation

Plain gates from both core and demo enable Cabal's actual component build information for
`hostbootstrap-core` with the pinned package-specific `build-info: True` project option. Resolve the
running core-test binary to its current plan row and that row's generated build-info JSON. Validate the
component/unit/compiler/package identities, then consume its exact compiler-argument array for test-context
module-map and compiler probes. Do not reconstruct an alleged actual exposure from expected lists or
rely on a one-time preparatory build, a stale artifact or project-local settings. Official Main-only probes
retain their separate minimal-package context.

Before implementation, record the complete forward and reverse import audit, current public surface,
source owners and completed path-pair evidence, component dependency graph, and compiler subjects
affected by the ownership change. The 57/29/28 and 52/5 counts describe the ownership and visibility scope,
not a substitute for the actual builds and compiler controls below. Verify the completed bounded relocation evidence before registration. No partially exposed or duplicated intermediate package
is accepted as a completed sprint.

The actual four hidden imports compile in `hostbootstrap-core-test` against the implementation used by
Main. `ImportHandoffRelay.hs`, `ImportHandoffProtocol.hs`, `ImportHandoffReceiver.hs`,
`ImportHandoffInternal.hs`, and the other existing private-import fixtures still refuse in the official
Main-only context with their newly measured exact diagnostics. Verify that reexported public types and
functions retain one shared identity, each relocated file is byte-identical with one production compiler owner, and
Main does not home-compile any relocated implementation. In the exact actual core-test context, compile
all four intended hidden imports positively and measure the 18 non-colliding hidden-module import
refusals. Inspect the compiler's complete per-module, per-unit origin entries for all 19 Main-needed
implementation identities, including `Lifecycle.Dependency.Internal`: the production origin is not selected
by a package flag or reexport even when a same-name DATA origin is independently exposed. The words
"hidden package" alone do not establish this property, because an explicitly selected module can also
carry that description. `Handoff.Rooted` remains one of the 18 refused imports until its separately owned
adoption. Existing DATA-unit routes retain their separate identities.

Add a same-context typed identity refusal using only ordinary opaque parameters and an existing public
consumer: a `ResourceCarrierCore` whose payload is the DATA unit's `RuntimeDependencyPackage` cannot be
passed to public `carriedResourceKeys`, whose Main alias fixes the production payload identity. Preserve
the corresponding Main `ResourceCarrier` positive. The actual compiler reason names both resolved unit
identities; measure and register that reason rather than guessing it. Do not allocate an authority, copy a
representation, use a cast, add a reader, or rely on `PackageImports` spellings that also reject the
selected positive module.

Run the focused private-import positives, actual public compile-fail group, HandoffSpec, all affected
metadata/source-ownership groups, ProjectPlanSpec, and DocValidatorSpec, then the four host static commands.
Record counts and outcomes from the coherent final package graph; do not weaken a diagnostic matcher or a
private-owner guard to accommodate a mistaken registration.

On 2026-11-01, an external base-only DATA packaging experiment with GHC 9.12.4, Cabal 3.16.1.0
and package specification 3.12 validates the proposed syntax: Main depends on its private sublibrary
and uses bare `reexported-modules`; the test dependency uses an explicit parser-only `mixins` list.
Disjoint roots compile one ordinary datum identity shared by a private parser and Main API. The actual
Cabal test flags contain exactly the thinned private unit, base and Main, with no second unthinned flag.
Main-only parser/helper imports refuse, the thinned context accepts the parser and refuses the helper,
and the actual Cabal test component refuses the helper before a restored positive passes. All probes
use resolved actual unit IDs; build and runtime positives exit zero, negatives exit one with GHC-87110.
This toy DATA experiment changes no repository source and establishes no hostbootstrap privacy or
acceptance claim; the real component graph, identities and compiler diagnostics are validated separately below.

The same external experiment additionally registers a separate DATA unit exposing the same `Toy.Helper`
name. Its actual test flags contain Main, that DATA unit, base, and only `Toy.Parser` from the implementation
unit. The unqualified DATA helper and selected parser compile, and the ordinary datum still passes through
Main with one identity. A compiler `-ddump-mod-map` probe in those same flags identifies the implementation
helper as an unselected hidden origin, the DATA helper as an exposed origin, and the selected parser as an
origin with a package flag. Package-qualified negative attempts are not privacy evidence: some spellings
also reject the parser positive, while the original package name can resolve the independent DATA helper.
This is packaging DATA research only; the real hostbootstrap module map, four positives, 18 import
refusals and separate DATA/production type-identity refusal have their own measured controls below.


On 2026-11-01, the native Windows library build `cabal build all` from `core/` passes with GHC 9.12.4,
Cabal 3.16.1.0 and the package warning policy (20:01:04.045009 to 20:02:31.845135 UTC; 87.801 seconds,
parent exit zero). The new private unit compiles its 57 modules and Main compiles its 92 remaining source
modules; the executable links. Installed metadata contains 15 local library units, the implementation
unit's 52 exposed and five hidden modules, and Main's unchanged 104 effective public modules plus 25
hidden modules. Main depends on the implementation unit; neither depends on the separate lifecycle
dependency DATA unit. All 57 production module bodies retain their saved relocation bytes.

The generated library build-info JSON validates the pinned package-specific project option and supplies
Cabal's actual compiler schema and argument array. This library-only build does not generate the test
component's JSON or establish its exposure. The test compilation, measured compiler-boundary controls,
focused groups and complete four-command host static gate below establish those separate properties.


The first native test-target build (`cabal build hostbootstrap-core:test:hostbootstrap-core-test`,
20:16:45.359188 to 20:18:44.802369 UTC; 119.444 seconds) exits one: `AuthoritySpec`'s new metadata
binding shadows an existing synthetic-description binding under `-Wname-shadowing` and `-Werror`.
The compiler scaffold and other changed metadata tests compile, but no test executable is linked and
no compiler-boundary test is claimed. The binding is corrected before the next coordinated build.


The 2026-11-01 reciprocal source reviews verify the exact forward closure and its 61 hidden reverse
imports from 23 remaining Main callers to 19 implementation members. The original 13 lower-library
stanzas and separate DATA routes remain byte-identical. Every original literal export pin is preserved;
24 individually reviewed facade lists extend the 73-entry set to 97 unique entries. Handoff's 26 hash
occurrences, 153 ordered assertion calls and all 109 physical-path arrays are unchanged. An independent
raw audit at 20:18 UTC confirms all 57 relocated bodies (2,174,191 bytes), their absent old homes and
178 unrelated source files (including demo and Python sources/tests) match their saved bytes. These
are source/metadata observations; the compiler and complete static gates have their own results below.


After the local binding rename, the same native test-target command passes and links the actual
core-test executable (20:19:56.641010 to 20:20:32.752933 UTC; 36.112 seconds, exit zero) with the
normal warning policy. Its current generated build-info JSON has the actual test component/unit,
GHC 9.12.4 and Cabal 3.16.1.0 identities and 97 compiler arguments. Exactly one private implementation
package selection contains the four intended module names, alongside Main and the existing DATA units;
there is no second unthinned implementation selection. The successful link alone does not establish
the refusal controls; actual runtime probes and exact diagnostic registrations establish them below.


The first actual test-context run at 20:21:10.957894 to 20:21:12.434947 UTC executes 29 controls
(1.477 seconds wall, parent exit one; one failure in 1.36 seconds). All 19 production-origin module-map
checks and the synthetic origin-parser controls pass. The Protocol, Relay, Internal and Main-carrier
positives pass. The Receiver positive reaches the real API but fails GHC-91028 because `seq` cannot
instantiate its remaining rank-2 callback type. Its positive witness therefore supplies the actual
unit-result continuations before remeasurement; no production authority or test access change is needed.


The Receiver positive with explicit unit-result continuations compiles under the unchanged actual
97-argument test context (20:22:40.342075 to 20:22:40.525718 UTC; 0.183648 seconds, exit zero, empty
stderr). All 18 non-colliding hidden-import subjects in that context produce GHC-87110 with their
full named hidden-package reasons. The separate DATA-carrier mismatch produces GHC-83865 naming
both the production handoff implementation and independent lifecycle-dependency DATA unit identities.
These ordinary opaque-parameter probes allocate no authority or representation.

In the unchanged official Main-only compiler context, all 20 moved-hidden import subjects are measured
again at 20:24:10.462683 to 20:24:12.240202 UTC and produce GHC-87110. All 19 affected qualified-type
subjects are measured at 20:24:23.514503 to 20:24:26.550324 UTC: their GHC-83865/GHC-18872 refusal
categories remain and their actual implementation-owner prefixes supply the registration expectations.
These measurements supply the exact registrations; the complete focused groups and four-command
gate have their own results below.


The final measured compiler registration adds six subjects exactly once, giving 608 physical fixtures;
all 602 original fixture bytes are unchanged, and 13 alternate-context subjects reuse their canonical
existing registrations. The exact matcher, live first-party inventory and original Main/DATA/representation
resolver spans remain unchanged. The final native test-target recompilation passes and links
(20:28:37.557075 to 20:28:46.007075 UTC; 8.450 seconds, exit zero). The first focused selector matches
zero tests and supplies no validation; the corrected boolean selector is checked against `--list-tests`
before execution and selects 1,894 tests across all eleven intended groups, including 720 public compiler
boundary cases and all 17 documentation cases. Its actual result is recorded below.

The Linux library-only preflight passes `cabal build all` from `/workspace/core` in the retained
`hostbootstrap-plan-gate-20261029` container (20:26:44.2341946 to 20:28:31.1711492 UTC; 106.9008615
seconds, parent exit zero). All 57 new private-unit modules compile; Main compiles 79 of its 92 source
modules with the remaining interfaces warm, and the executable links. The preflight first verifies all
57 saved raw hashes and absent old homes on both native and Linux checkouts, then copies only the three
frozen Cabal/project metadata files. It executes no tests. Full final-tree synchronization and the
complete Linux four-command static gate have their own validation below.


The native focused run executes those 1,894 cases at 20:29:30.242430 to 20:33:23.876945 UTC
(233.636 seconds wall; 233.51 seconds reported by Tasty). All 720 public compiler-boundary cases,
including the complete 48-case actual handoff test-exposure group, and all 17 documentation cases pass.
One of the 1,894 cases fails: `ClusterReconcileSpec`'s "the config binder is closed over both drivers
and every independent mismatch" reads a package-relative source path, while this direct binary invocation
incorrectly uses `core/` as its working directory. This is an invocation error, not a source edit or
ignored suite failure. The exact isolated case passes from Cabal's actual `core/hostbootstrap-core/`
package directory at 20:34:37.733748 to 20:34:37.859889 UTC (0.126138 seconds wall, 1/1, parent zero).
The complete Linux gate uses the normal Cabal runner and remains the final full-suite validation.

The canonical compiled `HostBootstrap.Digest.measurePathSetDigest` remeasures the Python floor's
`hostbootstrap`, `tests` and `pyproject.toml` paths at 20:33:38.686841 to 20:33:39.916258 UTC
(1.229425 seconds, exit zero, empty stderr). Its digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`, matching the current deferred
evidence. No Python or warm-store input changes are part of this registration sprint.


The final synchronization uses WSL stdin after a first transport attempt hits Windows' command-length
limit before launching WSL or copying source bytes; that attempt runs no tests. The successful sync
preserves Git HEAD, caches, dist directories and the Poetry environment. Its 877-file census is exactly
`core/hostbootstrap-core/{src,internal,test}` (sorted relative-path/SHA lines, digest
`9450acfb752d7aa1a78473144f8640d8d7be0e5ec8bdec63a05f455e8cbc92dc`). A separate broader audit
checks all 902 Haskell files across core, demo and warm-deps: the additional 25 app/provider-live/demo/
warm-deps files match too, with broad digest
`b902025b25238933fe3ab861395bfc7a9ae84310ed38389fe7301c284a7aeb0d`. All 95 governed documents
match at synchronization; later additions here record dated results only. These are dated synchronization
observations, not new freezes on shared files or future changes.

All four canonical Linux static legs start on 2026-11-01 at 20:34:08 UTC. The standalone `core/`
`cabal test all` passes all 3,791 tests in 250.75 seconds; Cabal reports PASS and parent exit zero
(20:34:08.2969818 to 20:40:49.4004499 UTC; 401.0702207 seconds command time including compilation).
Conditional accounting is emitted, including actual canonical-filesystem-root encoder `(1,0)`.
The default provider-live wrapper succeeds with its explicitly not-requested result, making no live
provider claim. The demo's own suite passes 165 tests in 1.35 seconds; its included core passes all 3,791
tests in 252.42 seconds. The complete `demo/` command passes at 20:42:18.4671686 UTC
(490.1212776 seconds from 20:34:08.3130421 UTC, parent zero). Python `check_code` passes (1.2104338 seconds, parent zero), and the unfiltered supported
`test_all` runner passes 376 tests in 5.94 seconds (7.049604 seconds command time, parent zero)
with 1,585 statements, 460 branches, no misses or partial branches, and 100% coverage.


Both core-suite runs emit the same 24 conditional families, with 59 supported rows and 20 explicit
refusals; their canonical-filesystem-root encoder row is `(1,0)`. The complete four-command static gate
therefore passes on the final frozen source graph. Its two default live-provider wrappers report that
the destructive live run is not requested; no hardware/provider acceptance is inferred.

Final delta measurement against the saved sprint baseline records zero production Haskell content edits
or relocations, 188 changed nonempty / 191 physical metadata lines across the three Cabal/project
files, and 1,406 nonempty / 1,453 physical test lines across twelve existing test sources and six new
fixtures. These metadata/test adoptions preserve the 57 implementation bodies, all 602 original fixtures,
all original export pins, role/type/caller/producer/order controls and separate DATA boundaries. The five
governed architecture/engineering documents describe the actual shared ownership and thinned test route.
The phase remains Active; its separate terminal gate is owed after every phase sprint closes.


The post-gate audit passes at 20:43:25.245 to 20:43:40.632 UTC (15.3439767 seconds, parent zero):
all 57 production bodies and absent old homes, 178 unrelated source files, the unchanged 13 lower private
stanzas, 15 installed local units, both frozen Haskell census scopes, all 608 fixtures and 602 original
fixture bytes match. All 109 physical-path arrays, 153 ordered assertion calls plus their two helper
definitions, 26 literal hash occurrences, owned response bytes and three Relay sections remain intact.
A mistaken helper label in the external audit is corrected before this successful audit; no source
mismatch or gate rerun occurs. The canonical Python-floor digest and retained container/process/mount
audits also pass. The sprint has no remaining implementation or validation work.


After setting Sprint 13.23 Done with no remaining work and advancing the queue to Sprint 13.24,
all 17 `DocValidatorSpec` cases pass natively at 20:45:16.046360 to 20:45:21.442282 UTC
(5.33 seconds reported, 5.395957 seconds wall, parent zero). The phase/table status, governed links,
implementation evidence and current deferred digest agree.

#### Remaining Work

None.


### Sprint 13.24: Exact protocol body and child-state DATA refusals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 100 changed nonempty lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Exercise the actual bounded Protocol decoder and child FSM through the shared private implementation,
reporting excess bytes precisely without inventing a field count or copying the protocol state identity.
Keep historical source freezes within the declarations their owning sprints introduced or changed.

#### Deliverables

- Preserve canonical protocol-v1 tags, field framing, bounds, and sequencing. Malformed, truncated, stale,
  replayed, wrong-edge, and wrong-domain inputs remain refused before an edge is admitted.
- When the expected fields are consumed but bytes remain, `decodeFields` returns
  `ProtocolExcessFields ProtocolTag Int Int` carrying tag, expected field count, and actual excess byte
  count. `protocolErrorMessage` renders those coordinates without an unmeasured field-count claim.
- An oversized outer body remains `ProtocolBodyTooLarge`; an oversized nested field declaration yields
  `ProtocolFieldTooLarge` without allocating its claimed payload. Preserve independent truncation and
  trailing-byte refusals.
- Direct value-level decoder tables require exact malformed-input constructors and coordinates, including
  both real excess-body shapes, through the implementation Main uses.
- Direct receive/send tables cover every illegal child-state/tag pair, including relay requests outside
  `ChildRunning`. Reach states through genuine transitions instead of a raw constructor or new test seam;
  Sprint 13.31 retains its exact rooted response/request-identity match and mismatch cases.
- Adopt the six whole-Protocol hashes and seven whole-Protocol line-count assertions into genuinely owned
  declaration/section evidence. Preserve independent semantic, closed-API, datatype, import, caller,
  producer, role, framing, ordering, and budget controls; shared-file totals are not another sprint's
  current-source oracle.

#### Validation

Through Sprint 13.23's shared private route, a canonical encode/decode positive precedes one crafted wire
for each exact `ProtocolTruncated`, `ProtocolBodyTooLarge`, `ProtocolFieldTooLarge`,
`ProtocolTrailingBytes`, `ProtocolBadMagic`, `ProtocolUnsupportedVersion`, `ProtocolUnknownTag`,
`ProtocolZeroRequestId`, and `ProtocolWrongFieldCount`. Assert every constructor coordinate. The field-limit
case has a valid small outer body containing a nested length header declaring `protocolMaximumBytes + 1`;
the body-limit case declares that oversized outer body instead. Neither allocates a giant payload or
fails at a smart constructor before the actual decoder runs.

An `OfferRequestTag` body with its valid field followed by three stray bytes yields
`ProtocolExcessFields OfferRequestTag 1 3`. A second body with that field followed by five empty extra
frames yields `ProtocolExcessFields OfferRequestTag 1 40`. Recompute each outer length so trailing bytes
cannot mask the intended branch. Pin the new renderer's complete message and retain existing independent
error-rendering contracts.

Build the initial, offer/challenge/grant/acceptance, running, six outstanding-response,
awaiting-acknowledgement, and finished states through successful real transitions. Use otherwise valid
messages for all tags, with matching request identity where required. Both `childProtocolReceive` and
`childProtocolSend` return exact `ProtocolInvalidTransition` values carrying the actual retained state and
attempted tag for every illegal pair. Include every relay-request tag outside `ChildRunning`, with
matching positive setup transitions. Require the sorted runtime tag-name multiset to equal the actual
`ProtocolTag` constructor names from the existing source reader, without deduplicating the list, and
require 13 distinct opaque reached states under their existing `Eq` instance. Exact aggregate counts
alone cannot conceal an omitted tag or state behind a duplicate. No copied module/state identity, raw
state constructor, authority-producing helper, or injected executor is permitted. These are codec/FSM DATA tests rather
than a recursive-process claim.

The actual acknowledgement path accepts its matching request identity and derived bytes, refuses a wrong
request identity with `ProtocolRequestMismatch`, refuses altered same-request bytes with
`ProtocolAcknowledgementMismatch`, and refuses a malformed Completed report with
`ProtocolLifecycleReportInvalid`. Preserve the outstanding response tag/request checks. These are actual
codec/FSM DATA observations and make no durable coordinator claim.

Before editing Protocol, measure fixed literal freezes from actual owned declarations/sections with the
existing readers and deterministic raw or structured-byte encoding. Reader errors fail. Expected hashes
must come from the saved baseline, never the current assertion subject. Adopt the affected guard subjects
without treating the unchanged complement of a shared module as their ownership:

- The parent-acknowledgement tags/FSM case keeps exact tag/field tables, real FSM/acknowledgement clauses,
  closed exports and datatypes, redaction, caller/producer/import inventory, and ordered assertions.
  Only a wholly owned definition such as `requireAcknowledgement` may carry an additional narrow
  literal freeze; the shared tag tables and child send/receive functions remain semantic/API subjects.
  Preserve `(343, 71, 414)` and its original budget
  as dated attribution evidence, without normalizing the changed shared file back to 541 lines.
- Rooted-request ownership and rooted-response pairing keep their existing owned Rooted/Handoff
  sections, definition bundles and literal hashes, singleton-field/tag contracts, neutral datatypes,
  roles, callers, producers, registration, and historical budgets. Any Protocol freeze covers only their
  consumed tag/field API; these cases do not own `decodeFields`, `ProtocolError`, or its renderer.
- Response authentication keeps its owned 119-significant-line, 6323-byte facade section and literal
  digest, owned portions of Internal/Rooted, all authentication/order/type/producer controls, and dated
  `(223, 13, 236)` attribution with its 240-line bound. It owns no whole-Protocol freeze.
- Rooted relay transport keeps its three actual owned Relay byte sections and concatenated digest,
  owned Receiver/Recovery/Internal/Rooted evidence, transport/import/caller/producer contracts, and dated
  two-owner attribution and 400-line bound. It owns no whole-Protocol freeze.
- Scope-first keeps its owned authenticated-scope Handoff bundle/hash, first-argument and
  import/caller/producer contracts. Carrier adoption keeps its owned package bundle/hash,
  payload-before-semantics ordering, four-field framing, and whole-body bound. Neither freezes unrelated
  decoder/error implementation.

Do not use an immutable shared-file complement, whole-file hash rebase, shared 541-line subtraction,
raised budget, or removed independent policy. Preserve the actual five Protocol data declarations and
separate three-datatype Rooted inventory under their closed-API checks; the new alternative belongs in
the existing `ProtocolError`. Every unaffected owned hash, raw section, role, import, caller, producer,
and ordering assertion remains. Historical measurements stay dated evidence rather than a new run.

Run focused HandoffSpec, the public compile-fail boundary, ProjectPlanSpec, and DocValidatorSpec, then all
four host static commands. Record actual results and the changed nonempty production budget. The separate
phase gate remains owed after all phase sprints close.


On 2026-11-01, the saved sprint baseline captures the unchanged 31,720-byte Protocol source with SHA-256
`59efed93557ddea190940e0b78acbfae120da8dc5b168eb6df0b833d2fc6d454`. The wholly owned
`requireAcknowledgement` baseline uses the existing `SourceGuard.haskellDefinitionClauseTokens` reader:
one clause, 45 tokens, encoded as the ordered Aeson `[(String, [[String]])]` bundle (483 bytes), then
hashed by the compiled `childConfigDigest`. Its fixed digest is
`116088b6fbcb48a1e31e920b6c8146362c6923fed4eec178e186f3ee28587b54`. Saved/current raw text,
clause arrays, serialized bytes and digest agree before the production edit. The external DATA helper
keeps all 97 actual test compiler arguments and adds only its explicit targets and temporary outputs.
Its initial compile omits SourceGuard as an explicit home target and fails; explicitly naming that
existing source target passes compilation at 20:37:00.504 to 20:37:04.460 UTC (3.956 seconds, exit
zero), then measurement passes at 20:37:04.460 to 20:37:04.534 UTC (0.0744 seconds, exit zero). Both
successful stderr streams are empty, with no repository or monitored build-configuration mutation.

The production delta is 15 changed nonempty/physical lines in Protocol alone. The explicit native
`cabal build hostbootstrap-core:lib:handoff-implementation-internal` command passes at
20:47:27.656981 to 20:47:32.588102 UTC (4.931 seconds, parent zero, normal warning policy), compiling
Protocol and its three affected Receiver/Relay dependents. Independent source review confirms the outer
body bound and all other decoder errors remain intact, and the new renderer contains only tag/count
coordinates. This library-only build establishes no completed runtime table, focused group or full
static gate; their actual results are recorded below.


The guard adoption changes 41 nonempty/physical test lines. It removes exactly six whole-Protocol
hashes, seven 541-line assertions and the 470-line complement calculation, retaining the owned Handoff
343 attribution and its dated 2026-08-11 `(343, 71, 414)` evidence. Only the measured acknowledgement
helper literal is added; all 20 unaffected hash occurrences, 153 existing ordered calls and their label/
fragment sequences, 109 physical-path arrays and 129 existing case labels remain exact.

Six runtime cases add 288 nonempty / 294 physical test lines, for a combined 329 / 335 test-line delta.
An independent exact rollback restores the accepted guard-only bytes. Source review checks the genuine
13 distinct opaque states, exact actual-source 24-tag multiset, 39 legal successor pairs, 585 illegal
pairs (293 receive / 292 send), 37 held-request mismatches, acknowledgement/report values, nine decoder
categories, three additional truncation layers and both reframed excess-body shapes. It finds no raw
state constructor, new authority producer, later admission API or unforced IO. These are source-review
observations accompanying the independently executed focused and full gates below.

The native final test-target build `cabal build hostbootstrap-core:test:hostbootstrap-core-test`
passes and links at 20:53:39.051388 to 20:54:08.292402 UTC (29.241 seconds, parent zero, normal
warning policy), rebuilding the affected Main consumers and HandoffSpec. The focused selector is checked
against `--list-tests` before execution: 135 Handoff, 720 public compiler boundaries, 108 indexed-plan
and 17 documentation cases, 980 total, run from Cabal's actual package working directory. The actual
focused result follows; the production budget remains 15 lines in one module.


The focused native run passes all 980 cases at 20:54:58.331644 to 20:57:47.637366 UTC
(169.22 seconds reported, 169.306767 seconds wall, parent zero). All six new protocol cases pass:
"the actual decoder distinguishes nine malformed-wire categories", "excess fields report remaining
bytes without counting invented fields", "every legal child-state tag pair has its exact successor",
"every illegal receive and send retains its actual opaque state and tag", "all request-bound legal
operations reject a different request", and "acknowledgement and lifecycle-report refusals are exact
values". All existing Handoff, public compiler, indexed-plan and documentation cases in the selector pass.

The final Linux sync verifies exactly Protocol and HandoffSpec changed among 902 Haskell files; the
other 900 files and all 608 compiler fixtures remain byte-identical. All 56 other relocated production
bodies and absent old source homes match, as do the unchanged Cabal/projects/compiler inventory and all
95 governed documents at synchronization. The broader 902-file aggregate is
`a6db2defa035519648c6b0cdaa1f00b94a531348ce3e307545fd228c97f5be25`; the owned
`core/hostbootstrap-core/{src,internal,test}` 877-file aggregate is
`1f1b4468c25aac4bfc13143a85f78b3e8353349d35eb55b69b60568e228bfb24`, each using sorted
relative-path/SHA lines. These are dated synchronization observations, not future source freezes.
The Linux library-only `cabal build all` passes at 20:56:52.8066956 to 20:57:08.8758750 UTC
(16.0358205 seconds, parent zero), rebuilding Protocol, affected consumers and the executable without
executing tests. The complete four-command gate below follows the focused pass.


On 2026-11-01, all four Linux host static commands pass on the frozen final sprint tree, starting at
20:58:48.7173728 UTC in the retained `hostbootstrap-plan-gate-20261029` container. The standalone
`core/` `cabal test all` passes 3,797 tests in 252.48 seconds, with Cabal PASS and parent zero
(279.0087242 seconds command time, ending 21:03:27.7665729 UTC). The `demo/` command passes its
own 165 tests in 1.44 seconds and the included 3,797 core tests in 250.65 seconds, parent zero
(286.4364632 seconds command time, ending 21:03:35.1951747 UTC). Both core runs emit the same
24 conditional families: 59 supported rows and 20 explicit refusals, including actual filesystem-root
encoder `(1,0)`. Both default provider-live wrappers explicitly report the live run is not requested;
these static results make no live provider or hardware claim.

Python `check_code` passes (1.2534088 seconds, parent zero). The unfiltered supported `test_all` runner
passes 376 tests in 5.88 seconds (7.3199246 seconds command time, parent zero) with 1,585 statements,
460 branches, no misses or partial branches, and 100% coverage. The compiled canonical ownership-unit
digest at 21:03:51 UTC returns
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`
(0.23365082 seconds, parent zero), preserving the current Python-floor evidence.

The final source audit passes at 21:03:51.099 to 21:04:07.695 UTC (16.5554181 seconds, parent zero):
all 902/877 frozen census subjects match, including the two deliberate changes, 56 unchanged relocated
bodies, 178 unrelated source files and all 57 absent old homes. All 608 compiler fixtures, package/project
metadata, compiler inventory, 13 lower-library stanzas and 15 local library units match their accepted
subjects. All 20 unaffected hash occurrences plus the narrow acknowledgement literal, 109 path arrays,
153 ordered calls, 129 original labels, six new cases and owned response/readers/Relay controls are
preserved. The process audit at 21:04:11 UTC passes (0.3445437 seconds, parent zero), retaining the
original container StartedAt, init and mounts, with no surviving test/probe children.

The sprint closes with 15 changed nonempty production lines in one module, 329 nonempty / 335 physical
test lines, aligned owned-freeze narratives and binary-context documentation, and no remaining work.
The phase remains Active; its own terminal gate is still owed after all phase sprints close.


After closing Sprint 13.24 and advancing the status table to the already Active Sprint 13.25, all
17 native `DocValidatorSpec` cases pass at 21:05:23.566887 to 21:05:30.027714 UTC (6.39 seconds
reported, 6.460869 seconds wall, parent zero). Phase/table harmony, owned evidence, governed links and
the current deferred digest agree; the scoped diff check is clean.

#### Remaining Work

None.


### Sprint 13.25: Verified config-handoff refinement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/SchemaSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 40 changed nonempty lines in one production module; no new field, type,
constructor, authority producer, or test-only admission route
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make transport proof and raw bytes insufficient to choose config or plan coordinates.

#### Deliverables

- `VerifiedHandoff scope brokerGeneration` remains transport-only and selects no plan, frame,
  configuration, verb, or lifecycle-phase phantom.
- `withVerifiedConfigHandoff` consumes the transport proof, exact `VerifiedConfigWire`, matching
  `ValidatedConfig`, and closed `ProjectVerb` in one refinement. The constructor-hidden wire/configuration
  pair shares one generative `configId` and the same canonical configuration digest from its joint producer.
- The refinement checks the signed payload kind, exact configuration-wire digest, specification digest,
  verb, and closed `Prepare | Execute | Teardown` phase. The validated value's identical digest follows
  from that joint wire/configuration identity; recovery reindexing preserves the identity and digest.
- Successful refinement yields fully indexed `VerifiedConfigHandoff scope planDigest brokerGeneration
  parentFrame childFrame configId verb phase` only inside a rank-2 continuation.
- Config-kind and recovery-kind grants remain distinct at the type boundary, so one kind cannot satisfy
  the other's refinement.
- Genuine paired configuration values, nominal/rank-2 compiler refusals, and exact runtime refusal details
  establish the boundary without raw constructors, casts, copied identities, or a new authority seam.

#### Validation

Preserve `HandoffSpec`'s transport/config separation, `SchemaSpec`'s payload-digest and raw-wire refusals,
and every independent nominal and rank-2 compile-fail control. Build each new case with an actual codec,
canonical configuration, real registered offer, challenge, grant, and successful transport verification.
Use the actual `projectCodecSpecDigest` for the matching fixture rather than `bindingInputFor`'s illustrative
specification text. Obtain the genuine wire/configuration pair through its existing joint admission.
The recovery-kind row may use public `withValidatedConfig` for that pair: it must reach
`withVerifiedConfigHandoff`, rather than stop at the earlier config-payload extractor.

Add four exact `Left (HandoffBindingMismatch detail)` cases:

- A recovery-kind signed handoff over otherwise matching canonical configuration bytes refuses with
  "the authenticated payload is not a project config".
- A handoff for configuration A paired with a separately admitted, genuinely different configuration B
  refuses with "the handoff and verified config wire digests differ". Both B values remain a matched
  wire/configuration pair; assert the actual digests differ and the wire guard wins. This row does not
  pretend that the signed digest can differ from only one member of a jointly admitted pair.
- A nonempty different signed specification digest, with payload/configuration, kind, verb, and phase
  otherwise matching, refuses with "the handoff and validated config specification digests differ".
- An unknown nonempty signed phase, with all earlier coordinates matching, refuses with
  "the handoff names an unknown lifecycle phase".

The existing "an up handoff cannot be refined as a teardown config edge" case must first demonstrate
matching `ProjectUp` refinement, then require exactly "the handoff does not authorize the requested project
verb" for `ProjectDestroy`. A broad binding-error match could be satisfied by an unrelated specification
mismatch, so the matching fixture uses the actual codec digest and both outcomes name their exact reason. Force every outer admission and inner result, and execute any returned
`IO` assertion action; a rejected continuation has count zero and the matching positive has count one.

There is no genuine well-typed validated-digest refusal after the wire-digest check passes: the only joint
producer gives the same canonical digest and `configId` to both opaque values, and reindexing preserves
them. Assert their actual digest equality on the matching route and retain a measured compiler refusal for
cross-pairing independently generated configuration identities, with a matching same-pair positive.
Do not manufacture a contradictory value to exercise an unreachable branch or guess the compiler category.
Run focused HandoffSpec, SchemaSpec, public compile-fail and DocValidator cases, then all four host
static commands on the coherent final tree. The phase gate remains owed after all phase sprints close.


On 2026-11-01, the production source review identifies the single joint mint used by canonical config
validation and authenticated byte admission. It passes one identical canonical digest into the opaque
wire and validated value under one fresh nominal `configId`. The sole recovery reindex preserves
that identity, digest and decoded value. No other production mint caller exists. Once the earlier wire
check passes, the validated-digest refusal is unreachable for ordinary public pairs. The source delta
removes just that two-line branch and adds the provenance Haddock: five changed nonempty / six physical
lines in Schema alone, with all other guards retaining their exact order and details. No import is
removed because `validatedConfigDigest` remains a public reexport.

Native `cabal build all` passes at 21:08:14.250233 to 21:08:25.415135 UTC (11.164980 seconds, parent
zero, normal warning policy), compiling Schema, affected Main consumers and the executable. This is a
library/executable preflight, not the focused or full suite. The HandoffSpec source adoption changes
91 nonempty/physical lines: a matching actual-codec-spec Up control and exact Destroy refusal, plus the
four exact otherwise-matching kind, A-versus-B wire, specification and unknown-phase refusals. Every
admission/result/returned IO action is forced, with expected callback counts one/zero. Exact reversal
restores the saved baseline; all 135 previous labels, 21 hash occurrences, 153 ordered calls, 109 path
arrays and the complete protocol DATA tables remain unchanged. Actual runtime results follow below.

The public matching-pair compiler control passes with empty stderr at 21:09:43.572137 to
21:09:43.717287 UTC (0.1451638 seconds, exit zero). Its otherwise identical cross-pair subject fails
at 21:09:43.717478 to 21:09:43.872448 UTC (0.1549834 seconds, exit one, GHC-25897): the actual reason
is "Couldn't match type 'configIdB' with 'configIdA'", followed by expected/actual `ValidatedConfig`
types carrying the two identities. Both use the existing actual Main-only resolver: GHC 9.12.4, current
package databases, explicit hide-all-package context and sole Main unit
`hostbootstrap-core-0.1.0.0-inplace`. Neither exposes a private unit or constructs an authority.

The measured cross-pair subject adds 17 nonempty / 20 physical lines (619 bytes); its exact registration
and inline matching control add 37 / 38, for 54 / 58 compiler-test lines. All 608 existing fixtures and
the resolver, matcher, normalizer and live definition/inventory logic remain byte-identical; the canonical
fixture set has 609 members. The matching inline source is byte-identical to the measured positive.
Existing Forge/Coerce/Escape controls remain. These measurements establish the direct type barrier;
normal component compilation and focused results follow, with the complete static gate separately recorded.


The final native `cabal build hostbootstrap-core:test:hostbootstrap-core-test` passes and links at
21:12:23.370232 to 21:13:54.520525 UTC (91.150858 seconds, parent zero, normal warning policy).
A direct four-case run then passes the matching/exact-verb runtime case, all four reachable refusal
rows, matching compiler control and cross-pair negative (21:15:10.359852 to 21:15:10.964438 UTC;
0.53 seconds reported, 0.604591 seconds wall, parent zero). The independent compiler-lane review verifies
that reversing only its three added chunks restores the entire baseline resolver/matcher/inventory
source, and the inline positive is byte-identical to the measured external matching source.

The complete focused selector is checked against `--list-tests` before running from Cabal's actual
package working directory: 136 Handoff, 59 Schema, 722 public compiler and 17 documentation cases.
All 934 pass at 21:15:30.810003 to 21:17:45.752138 UTC (134.86 seconds reported, 134.942964 seconds
wall, parent zero), including all existing transport, payload, nominal and rank-2 controls.

The final Linux sync verifies exactly Schema, HandoffSpec and CompileFailSpec changed among the 902
existing Haskell files, with the sole new path the 619-byte cross-pair fixture. All other 899 files, all
608 existing fixtures, package/project metadata and 56 other relocated production bodies including
Protocol remain unchanged. All 95 governed documents match at synchronization. The complete 903-file
aggregate is `fb20d7d63a1d42abb6f6fea043cbd454f12a0da9be60931f45fc8d8b88768307`; the
`core/hostbootstrap-core/{src,internal,test}` 878-file aggregate is
`c93e0dd6d2520fcb480e5e3e27b8d9880d2b690b6ee4d0b8805910df9e0c950a`, using sorted relative-path/
SHA lines. These are dated synchronization observations, not future source freezes. Linux library-only
`cabal build all` passes at 21:17:33.6439859 to 21:17:50.0845108 UTC (16.4024083 seconds, parent
zero), rebuilding Schema, affected consumers and the executable without running tests. The four-command
static gate below follows the focused pass and validates the coherent final tree.


On 2026-11-01, all four final Linux host static commands pass in the retained gate container.
Standalone `core/` `cabal test all` passes 3,800 tests in 246.16 seconds with Cabal PASS and parent
zero (21:18:24.4849270 to 21:24:11.9792326 UTC; 347.462492 seconds command time). The `demo/`
command passes its own 165 tests in 1.35 seconds plus the included 3,800 core tests in 245.70 seconds,
parent zero (21:18:24.4931304 to 21:24:19.4225312 UTC; 354.8976954 seconds command time). Both
core suites emit the same 24 conditional families: 59 supported rows, 20 explicit refusals, and actual
filesystem-root encoder `(1,0)`. Both default provider-live wrappers explicitly report the live run is
not requested; these results make no live provider or hardware claim.

Python `check_code` passes (1.2067666 seconds, parent zero). The unfiltered supported `test_all` runner
passes 376 tests in 5.78 seconds (7.1188479 seconds command time, parent zero), with 1,585 statements,
460 branches, no misses or partial branches and 100% coverage. The canonical compiled ownership-unit
digest at 21:24:28 to 21:24:29 UTC returns
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`
(0.189418856 seconds, parent zero), preserving current Python-floor evidence.

The final source/fixture audit passes at 21:24:28.6204761 to 21:24:51.7625841 UTC (23.1023739
seconds, parent zero): frozen 903/878-file aggregates match, exactly three existing Haskell files change
and the 619-byte fixture is the sole addition. All 899 other existing files, 608 prior fixtures, 56
other relocated bodies including Protocol, 178 unrelated source files and all 57 absent old homes
match their saved subjects. All 609 final fixture bytes, metadata subjects, 21 Handoff hash occurrences,
109 path arrays, 153 ordered calls, 135 prior labels and the complete six-case protocol DATA section
match; only the intended refinement label is added. The process/metadata audit at 21:25:04 to
21:25:05 UTC passes (0.3594927 seconds, parent zero), retaining the original container StartedAt, init
and mounts without surviving test/probe children.

The sprint closes with five changed nonempty / six physical production lines in one module and
145 nonempty / 149 physical test lines across HandoffSpec, CompileFailSpec and its new fixture. The
governed boundary documentation matches the joint identity/digest provenance and retained refusal order.
There is no remaining work in the sprint. The phase remains Active until its other sprints and own
terminal gate close.


After closing Sprint 13.25 and advancing the status table to the already Active Sprint 13.26, all
17 native `DocValidatorSpec` cases pass at 21:26:11.049019 to 21:26:16.418053 UTC (5.30 seconds
reported, 5.369069 seconds wall, parent zero). Phase/table harmony, governed links, implementation
evidence and the current deferred digest agree; the scoped diff check is clean.

#### Remaining Work

None.


### Sprint 13.26: Child-plan authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Child/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across the existing Construct and Handoff
modules; no authority representation change or public API expansion
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`, `DEVELOPMENT_PLAN/rationale.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`, `DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md`

#### Objective

Admit the exact fresh child plan named by a refined config handoff without granting lifecycle execution. The
check that the signed child frame is the frame the admitting binary runs is the recursive lifecycle command
phase's (Phase 17), whose child entry supplies the running frame.

#### Deliverables

- `withChildProjectPlan` consumes one `VerifiedConfigHandoff`, the same verified wire/configuration, and
  non-empty plan drafts. The refined handoff and supplied singleton already fix the same verb, and the
  wire/configuration share the already-refined generative `configId` and canonical digest.
- Admission derives the lifecycle profile's installed project, protected store, scope/profile name, and
  broker generation from the authenticated binding. Drafts carry root/specification/configuration evidence,
  not an independently stamped project/store/broker origin. The specification digest is bound by the prior
  config-handoff refinement.
- Fresh plan construction retains the draft root and exact validated configuration, performs the existing
  structural/draft checks, and compares the actual stable snapshot digest with the signed plan revision.
- One rank-2 continuation jointly receives the fresh local `ProjectPlan`, exact `PlanDigestBinding`, and
  fully indexed opaque `ChildPlanAuthority`.
- Child-local plan and configuration identities are generative, and tokens, receipts, and generative
  handles are never serialized as plan authority.
- `ChildPlanAuthority` contains no `ProtectedStore`, acquisition journal, lifecycle cursor,
  `CommandAuthority`, root invocation authority, or signing capability.
- Direct observed results and genuine Production/Harness fixtures establish admission without a new
  authority producer, copied implementation, cast, injected validator, or execution claim.

#### Validation

Preserve every existing construction, escape, and cross-index compile refusal and the independent root,
specification/configuration-draft and structural validation controls. `withChildProjectPlan` is pure, so
its callback returns observed values rather than an assertion action. `ProjectPlanSpec` compares those
values after every outer admission has returned, within the actual broker/run lifetime.

Closure requires these cases:

- Return `(childPlanAuthorityBinding authority, stablePlanSnapshotDigest (renderSnapshot childPlan))`
  from the joint callback and compare it with `(relayBinding relay, actualParentPlanDigest)` after forcing
  all result layers. Also assert the public child project name and profile name against the corresponding
  authenticated project/scope evidence. The binding equality retains the actual signed store and generation;
  source/type checks establish that those fields, rather than invented draft-origin evidence, feed the plan
  admission kernel. Do not add a getter to expose unavailable internal coordinates just for the test.
- Use an actual owned Harness run, its real Harness authority and matching codec/configuration admission,
  and a genuinely signed `Harness <run>` handoff. Require the admitted child's public profile name to equal
  `"harness:<run>"`, the actual project and retained binding to match, and every owned-run acquisition and
  cleanup/result layer to succeed. Use existing phase-lawful producers; this is child-plan admission, not a
  later recursive lifecycle/Harness coordinator integration test.
- Strengthen the existing signed-revision case to assert the complete actual
  `AuthorityMalformedBinding` produced by rendering
  `PlanHandoffEvidenceMismatch "stable plan digest" signedRevision actualChildDigest` with the existing
  `"child plan admission failed: "` prefix. Derive both digest values from the actual signed binding and
  admitted matching control, assert they differ, and preserve all other matching inputs. A substring or
  arbitrary authority failure cannot stand in for this refusal.

There are no independently mismatched project/store/broker draft fields for three additional runtime
refusals: those profile coordinates are derived from the signed handoff. Likewise the singleton verb and
joint wire/configuration identity make Construct's three repeated checks unreachable for a well-typed
caller. Preserve the real config-handoff runtime refusals and nominal/rank-2 proofs at their admission
boundary; do not invent authority values or retain redundant defensive guards for those impossible rows.

Removing the unused frame-error alternative changes a shared file outside the historical response-signing
increment. Adopt only ownership-scoped HandoffSpec freezes affected by that change: retain the fixed named
wrapper bundles and actual 119-line/6,323-byte owned response section with its unchanged raw-byte digest,
plus every independent role, producer, import, type, order, redaction, wire, and protocol assertion. Keep the
historical 3,521-line/223-plus-13-equals-236/240-line evidence as dated attribution rather than rebasing a
live whole-Handoff count or subtracting an unrelated current delta. Existing public-reader ownership
controls remain independent.


On 2026-11-01, the production adoption changes 36 nonempty/physical lines across two modules:
Construct 32 and Handoff four. Construct consumes the prior config refinement, removes its three
redundant verb/wire/value checks, unused local helper and four imports, and forces the retained verb
and wire witnesses after successful scope decoding. Kernel arguments, signed-origin derivation,
draft/configuration admission, stable revision comparison and recovery calls remain unchanged. The
handoff error vocabulary omits its never-produced frame alternative and message arm, with an
independent lexical absence case; the completed deletion-ledger row is absent. Public functions and
authority representations are unchanged; no public surface is added.

The HandoffSpec adoption changes 27 nonempty/physical lines: owned response/capability measurements
replace live shared-facade subtraction, preserving all 21 hash occurrences, 153 ordered calls and
109 physical-path arrays. The actual response remains 119 significant lines / 6,323 bytes with its
fixed `8017cb84eb922ba3448e54e5fa33ed1d825798089fe7190d52842a0e9827fe69` digest, and all 13
binding-reader/26-line controls remain. Original 139/180 landing evidence and 3,521-line / `(223,13,236)`
against 240 bookkeeping stay dated attribution; no whole-file count, complement or digest is rebased.

ProjectPlanSpec changes 241 nonempty/physical test lines, returning and comparing the actual Production
binding/digest/project/profile tuple, deriving a matching digest before the exact revision-only refusal,
and joining an actual owned Harness run/profile/spec/codec. Typed binding comparisons stay within the
broker/run lifetime; only descriptive observations escape after acquisition and cleanup succeed. Precise
rollback restores both saved test baselines outside their accepted spans; all existing labels, hashes,
ordered requirements, paths, protocol tables and config-refinement cases remain. Combined test delta
is 268 nonempty/physical lines. Independent source reviews find no new authority producer, origin
getter, cast, representation copy or later coordinator API.

The native test-target build `cabal build hostbootstrap-core:test:hostbootstrap-core-test` passes and
links at 21:32:46.297516 to 21:34:45.318469 UTC (119.021686 seconds, parent zero, normal warning
policy), rebuilding the affected shared-unit/Main/test consumers. The direct four-case run passes
"an authenticated config edge jointly admits the exact child plan and authority", "child admission
refuses a signed revision other than the stable child plan digest", "an owned Harness config edge
admits the exact run profile and child authority", and "handoff errors omit the dormant frame-mismatch
alternative" (21:37:15.338248 to 21:37:15.621335 UTC; 0.20 seconds reported, 0.283088 seconds wall,
parent zero). The complete focused and four-command results follow below.


The first complete focused run executes 985 cases at 21:37:41.976603 to 21:40:33.534602 UTC
(171.47 seconds reported, 171.559052 seconds wall, parent one). All changed runtime cases, Handoff,
public compiler and documentation cases pass; the sole failure is ProjectPlanSpec's "forward-child
projection ownership is hidden, fixed-unit, acyclic, and frozen". Its whole-Construct hash and following
631-line/216-plus-one-equals-217 arithmetic freeze unrelated child-admission implementation. This is
expiry of an unowned shared-file oracle, not an accepted failing test or a rebase of that oracle.

The projector owner retains five unchanged Construct forwarding declarations. An external DATA helper
uses the actual SourceGuard readers on the saved sprint baseline: their typed tokens (184) and complete
single clauses encode as ordered Aeson `([String], [(String, [[String]])])` bytes (2,458), yielding fixed
saved-baseline digest `c49bb152f01599b443a774dc506b11655665f209a31f3ab11b2b14f38c2326bd`. Current
tokens, clauses, bytes and digest agree. All 97 actual test compiler arguments are preserved; compilation
passes at 21:45:47.771042 to 21:45:51.190347 UTC (3.419311 seconds, exit zero), and measurement passes
at 21:45:51.190395 to 21:45:51.255023 UTC (0.064618 seconds, exit zero), both with empty stderr and
no repository/build-configuration mutation. No expectation is derived from an edited current subject.

The reviewed 68-line test adoption freezes only that five-declaration typed/complete-clause section,
requiring the exact discovered-name inventory and one real clause each. Original shared-file hash,
size and complement arithmetic become dated attribution. The independent private-owner hash/count226,
CLI minimum/count policy, one metadata registration and all export, constructor, role, importer, caller,
projector-order and CLI installation assertions remain. The finalized-projector owner's narrative
reflects that scope; its separate genuine-projector/bare-CLI runtime obligations remain Active. The
corrected compilation and focused results follow. Combined test delta is 336 nonempty/physical lines.


The corrected test-target recompilation passes at 21:52:29.654208 to 21:52:50.323622 UTC
(20.669549 seconds, parent zero, normal warning policy). The repaired ownership case and all 17
documentation cases then pass together: 18/18 in 8.08 seconds reported (21:55:04.494096 to
21:55:12.641834 UTC; 8.147786 seconds wall, parent zero). The independent applied-diff review confirms
the fixed baseline bundle and all unaffected controls; only the approved date/spacing comments differ
from the reviewed proposal. The complete focused rerun result follows.

The complete corrected focused run passes all 985 cases at 21:55:19.143661 to 21:58:22.729189 UTC
(183.49 seconds reported, 183.586688 seconds wall, parent zero): 137 Handoff, 109 indexed ProjectPlan,
722 public compiler boundaries and 17 documentation cases, including the repaired forward-child
ownership case. No failing result is treated as completion evidence.

The initial Linux library-only `cabal build all` preflight passes at 21:39:35.5883152 to
21:40:22.0578411 UTC (46.4223942 seconds, parent zero), rebuilding Handoff/Construct consumers and
linking the executable without tests. That production result remains valid through the test-only guard
repair. The corrected resync copies only ProjectPlanSpec among Haskell sources plus governed docs;
all 903 source hashes and 609 fixture bytes match the final snapshot. The corrected 903-file aggregate
is `69b167e7a01a2dad85a79dd81803127fbc0a2771db1ec0131a3f2b5893a8ac11`; the owned
`core/hostbootstrap-core/{src,internal,test}` 878-file aggregate is
`b54b1ffd5eb5ef250bd5932b8f708943de58fb2534dbfc9db85a75f9ea902cc9`, using sorted relative-path/
SHA lines. Other 899 baseline files, 56 other relocated modules, old source-home absence, metadata and
all independent control subjects remain unchanged. These are dated sync measurements, not shared-file
freeze expectations. The full four-command gate starts only after this corrected focused pass.


On 2026-11-01, all four corrected Linux static commands pass in the retained gate container after
the complete corrected focused pass. Standalone `core/` `cabal test all` passes 3,802 tests in
252.16 seconds, with Cabal PASS and parent zero (22:00:38.8033578 to 22:06:39.1335098 UTC;
360.2916932 seconds command time). The `demo/` command passes its own 165 tests in 1.47 seconds and
the included 3,802 core tests in 249.02 seconds, parent zero (ending 22:07:15.5666061 UTC;
396.7248502 seconds command time). Both runs emit 24 conditional families, 59 supported rows and
20 explicit refusals, including actual filesystem-root encoder `(1,0)`. Both default provider-live
wrappers explicitly report the live run is not requested; no provider or hardware acceptance is inferred.

Python `check_code` passes (1.2746339 seconds, parent zero), and the unfiltered supported `test_all`
runner passes 376 tests in 5.85 seconds (7.2605012 seconds command time, parent zero), with 1,585
statements, 460 branches, no misses/partial branches and 100% coverage. The canonical compiled
ownership-unit digest at 22:07:35 to 22:07:36 UTC returns
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`
(0.233207721 seconds, parent zero), preserving current Python-floor evidence.

The final source audit passes at 22:07:35.5016058 to 22:07:59.8613081 UTC (24.3219855 seconds,
parent zero). Corrected 903/878-file aggregates match; exactly four owned files change and all other
899 Haskell files, 609 fixtures, 56 other relocated bodies including Protocol/Schema and all 57 absent
old homes match their saved subjects. All 21 Handoff hashes, 109 arrays, 153 ordered calls and complete
protocol/config cases remain. ProjectPlanSpec replaces only its unowned whole-Construct literal with
the fixed five-declaration bundle; every other PP hash is preserved. The current Handoff is 200,195
bytes; the owned response section, reader evidence and Relay sections are unchanged. The dormant
error is absent from production. All seven metadata subjects match. Process audit at 22:08:04 to
22:08:05 UTC passes (0.387135 seconds, parent zero), retaining original container StartedAt, init
and mounts without surviving test/probe children.

The sprint closes with 36 changed nonempty/physical production lines across Construct and Handoff,
336 nonempty/physical test lines, aligned boundary/rationale/ownership documentation and no remaining
work. The phase remains Active until its other sprints and own terminal gate close.


After closing Sprint 13.26 and advancing the status table to the already Active Sprint 13.27, all
17 native `DocValidatorSpec` cases pass at 22:09:51.928409 to 22:09:57.706521 UTC (5.71 seconds
reported, 5.778148 seconds wall, parent zero). Phase/table harmony, current deferred evidence,
owned-freeze rationale, governed links and implementation citations agree; the scoped diff check is clean.

#### Remaining Work

None.


### Sprint 13.27: Build invocation authority protocol [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Production budget**: at most 400 changed nonempty lines in the existing Build module; declare any
necessary direct byte-path dependency in the existing component
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`, `documents/engineering/cabal_layout.md`

#### Objective

Define the signed, measured authority protocol consumed by an image-build frame.

#### Deliverables

- `BuildBinding` binds the project/spec/config identity to measured source-root and builder-path inputs.
- Verification uses the independently installed Build key and a coordinator-scoped signed grant.
- One verified exchange jointly yields `ImageBuildFrame` and `BuildInvocationAuthority` inside its
  bounded continuation. Each returned authority authorizes each narrow build/check-code phase at most
  once, and absence of a coordinator is a typed refusal.
- The protocol grants no ordinary developer command authority; the worked-demo phase owns trusted
  engine/runtime derivation and the concrete derived-image delivery and consumer. This verifier checks
  its supplied source/builder paths and keeps no durable replay registry.
- The source digest measures regular-file relative names and their content bytes only. Names have one
  lossless canonical byte encoding: POSIX name bytes remain exact; Windows UTF-16 name units use a
  reversible UTF-8-compatible encoding: combine valid surrogate pairs, and encode an unpaired unit
  as its three-byte WTF-8 sequence without replacement. Ordinary shared names therefore have the same UTF-8 bytes on Windows, Linux and
  the container. Relative components are joined with the single byte `/`, entries are ordered by their
  canonical relative-name bytes, and the existing length framing of name then contents is retained. The
  absolute measuring root, locale, modes, empty directories and symlink-versus-copy are not measured;
  no case folding or Unicode normalization changes a name.
- A source entry or builder path that is not a regular file or directory of the allowed traversal is
  classified before opening it: FIFO, socket and device entries produce typed unavailability rather than
  a blocking read. File-read/traversal failures catch `IOException`; asynchronous exceptions propagate
  instead of becoming typed Build refusals.
- The channel decoder bounds each declared length as a `Word64` before narrowing it, using the existing
  bounded Handoff framing contract. An oversized length is `BuildChannelMalformed`, never an empty field;
  exact field count, UTF-8, signature-frame and trailing-byte rules remain enforced.

#### Validation

Preserve `BuildAuthoritySpec`'s provisioned-key and signature-domain checks, coordinator lifetime,
non-ASCII filename controls, binary measurement, one-use phase consumption and typed refusals. The
"moving bytes to a different name" case performs a genuine rename with unchanged entry count and
contents. The no-channel case establishes `readBuildChannel`'s typed unavailability; Command retains
its independent no-fallback policy control.

Closure requires the following genuine filesystem and channel cases:

- The same nested tree under two different temporary roots measures equal digests. The fixed two-file
  tree (`a.hs` = `"x"`, `src/b.hs` = `"y"`) has a literal golden digest. A shared ordinary non-ASCII-name
  vector also has the same literal digest on native Windows and Linux; the host-to-VM-to-container source
  context must not acquire UTF-16LE name bytes on one side and UTF-8 on another. Measure and review the
  literal framed-byte inputs independently and check the real implementation against those fixed
  expectations; do not compute expected values through a production codec during the test.
- A genuine rename deletes `Main.hs` after writing `Renamed.hs`, preserving entry count; the digest
  changes. The boundary-shift pair `{a: "bc"}` / `{ab: "c"}` also differs, proving the framing subjects.
- On POSIX, real files whose names are the single undecodable bytes `0xFF` and `0xFE` measure differently.
  Retain the existing ordinary non-ASCII cases and verify the actual path enumeration does not round-trip
  through replacement-decoded `FilePath`/`Text`. Windows canonical-name coverage uses actual ordinary
  names including a non-BMP scalar. Where the actual filesystem preserves unpaired UTF-16 names, compare
  a real unpaired-unit name against the replacement-character name and require different digests, first
  checking the enumerated raw names are distinct. If that filesystem cannot represent such a name, report
  the measured capability branch through the standard conditional accounting rather than claiming the
  losslessness case passed. No locale-dependent fallback is accepted.
- On POSIX, a real FIFO under the source root and a FIFO at `builderPath` each return the correct
  `BuildSourceUnavailable` / `BuildBinaryUnavailable` with the exact non-regular reason and actual
  relative source path / builder path, within a five-second bound. `Nothing`, a swallowed timeout, an
  arbitrary `Left`, or a different IO setup error is not a passing refusal. Scoped source/type controls
  require the actual Build filesystem catches to be `IOException`, preserving asynchronous cancellation
  rather than claiming an injected executor or nondeterministic timing test proves it.
- Delete the real builder only after producing an otherwise valid signed fixture, and require its actual
  `BuildBinaryUnavailable`; likewise delete the source root and require `BuildSourceUnavailable`.
  Every surrounding signature/project/spec/config/coordinator value remains valid and the admission
  callback stays uncalled.
- Through the real `readBuildChannel`, a table asserts the exact `BuildChannelMalformed` detail for a
  header shorter than eight bytes, a truncated field body, declared `0xFFFFFFFFFFFFFFFF`, a non-UTF-8
  field, and trailing bytes after the signature frame. The maximum `Word64` case preserves the actual
  bounded-Handoff framing refusal when mapped to Build's category; no `Int` conversion precedes that
  decision. An otherwise valid empty image-build frame is accepted by the reader and then refused by
  verification with `BuildChannelMalformed "the image-build frame is empty"`. An otherwise valid
  63-byte signature frame likewise reaches verification, which returns `BuildSignatureInvalid` with
  the actual measured parse-failure detail; do not guess that library message or let an earlier field
  mismatch satisfy either case.
- Name the no-channel case for its actual reader property, `BuildChannelUnavailable`, and retain
  Command's independent no-fallback contract. Run the focused Build cases and all four host static
  commands on the final tree; record actual native/Linux/platform-specific branches and literal byte
  vectors. No image-build or remote-engine acceptance is claimed by these static fixtures.

On 2026-11-01, implementation changes 210 nonempty lines (214 physical) in Build only. Native
OsPath traversal and strict reads retain POSIX bytes or reversible UTF-8/WTF-8 Windows name units.
Metadata rejects non-regular subjects before reads. Four filesystem catches use IOException; channel
framing delegates its Word64 bound to the existing Handoff reader before narrowing. Public exports
and the complete authority/producer/phase-policy tail remain byte-identical. Main and core-test add
only direct declarations of the installed boot file-io package. No Dockerfile or warm-store input changes;
no base publication is triggered. The two governed engineering documents describe these exact subjects.

The native `core/` `cabal build all` preflight passes at 22:15:13.621276 to 22:15:46.662686 UTC
(33.041624 seconds, parent zero, normal warning policy). Independent native-filesystem DATA probes
retain distinct ordinary, non-BMP, unpaired and replacement names on this Windows filesystem. Actual
Linux probes enumerate and read exact FE/FF filename bytes and classify a genuine FIFO without reading
it. These API experiments do not claim image-build or remote-engine acceptance.

Independent DATA vectors fix exact byte-sorted name/content inputs and unsigned-64 big-endian frames:
two-file 46 bytes, ordinary Unicode 50, non-BMP 24, boundary pairs 19 each, raw FE/FF 18 each, and
unpaired/replacement 20 each. All nine literal SHA-256 values are independently recomputed and reviewed;
no expected digest calls a production codec. The ordinary Unicode name hex inputs `cebb2e6873` and
`e4b8802ff09f98802e6873`, with contents `78` and `79`, yield literal digest
`be72e391ed23e1a4cfc9fd89a7637692e0d66ac4e89eba0dbf931f50dfa3294c`. Non-BMP
`f09f98802e6873` retains its own literal vector. Native-only pairs use exact names `fe` / `ff` and
`eda080` / `efbfbd`, each with contents `78`, distinct in actual enumeration and fixed digests.

BuildAuthoritySpec changes 311 nonempty lines (321 physical): 39 direct cases plus registered families
of three POSIX cases and one Windows case. Both unavailable-platform branches invoke their real
ownership primitive, require its complete typed Unsupported reason and prove no file appears. Windows
support additionally uses one shared actual filename probe; only InvalidArgument from the unpaired-name
write can constitute capability refusal. Control, enumeration and cleanup errors fail. The actual rename
preserves file count and contents; exact typed FIFO refusals fail on timeout. Valid signed controls precede
missing-input, empty-frame and malformed-signature refusals and force their callback counts. Existing
provisioned-key tests and the fixture/helper tail remain byte-identical. CoverageManifest adds only its
import and these two declarations; all 24 prior family declarations remain unchanged.

The actual current-Main verifier/channel probe compiles at 22:20:24.312473 to 22:20:25.735999 UTC
(1.423537 seconds, exit zero, empty stderr) and runs at 22:20:25.736064 to 22:20:25.830229 UTC
(0.094174 seconds, exit zero, empty stderr). Its matching signed control enters once. Short-header,
truncated-body, maximum Word64, non-UTF-8 and trailing-byte rows yield their exact decoder details.
Empty image-frame and 63-byte signature controls pass the reader then fail verification with callback
zero; the latter actual reason is `BuildSignatureInvalid "CryptoError_SecretKeyStructureInvalid"`.
The final tests use those measured literals. An initial external helper compile refusal was corrected
with explicit String signatures before its first actual verifier execution, retaining warning policy.

The first native test-target build stops at 22:25:07.043555 to 22:25:42.975890 UTC (35.932562
seconds, parent one): the new source supplement gives an argument to SourceGuard.readPackageDescription,
whose existing type is IO String. Removing only that argument compiles and links at 22:26:22.996333
to 22:26:30.547578 UTC (7.551290 seconds, parent zero, normal warning policy). No failing result is
completion evidence. All 43 actual Build cases then pass on native Windows at 22:26:57.281203 to
22:26:57.556707 UTC (0.24 seconds reported, 0.275509 seconds wall, parent zero), including the actual
supported unpaired-name case and three explicit POSIX capability refusals.

The Build/Handoff/documentation segment passes 200 selected tests at 22:26:57.557117 to
22:27:38.830618 UTC (41.18 seconds reported, 41.273767 seconds wall, parent zero): 43 Build cases,
two matching manifest declarations, 137 Handoff, 17 documentation and one public fixture selected by
the source-module spelling. Actual tree labels select the remaining 109 indexed-plan/declaration and
722 public compiler-boundary cases separately. All 831 pass at 22:27:50.181028 to 22:29:57.728297
UTC (127.47 seconds reported, 127.548073 seconds wall, parent zero). Across the two segments every
required focused group passes; the extra public fixture is also in the complete compiler group.

The Linux library-only `cabal build all` preflight passes at 22:30:24.2781491 to 22:31:00.7335459
UTC (36.4209435 seconds, parent zero), recompiling Build and linking the executable under normal warning
policy. Final synchronization matches all 903 Haskell sources and 609 fixtures. Exactly Build,
BuildAuthoritySpec and CoverageManifest differ from the sprint baseline; other 900 sources, all 57
relocated bodies and all 97 export-pin declarations and literal blocks are unchanged. The dated sorted relative-path/SHA
aggregate is `702d55d95ed4806ca88afd1c479fe33d9cad7bda9e4e887cb656e770ccc20295`; the owned
878-file aggregate is `a964cf0375711532ec1586a38f4d37a422b1a9bbeca1a265922c9d2d1bccf55f`.
These synchronization measurements are not shared-file freeze expectations. The Cabal audit confirms
only the two direct file-io edges; all 14 private components and both project files are exact.

All four Linux static commands launch at 22:31:13 UTC after the complete focused pass. Python
check_code passes (1.2250011 seconds, parent zero); unfiltered supported test_all passes 376 tests in
6.05 seconds (7.4480577 seconds command time, parent zero), with 100% statement/branch coverage.
Standalone `core/` `cabal test all` passes all 3,819 tests in 247.50 seconds, with Cabal PASS and
parent zero (22:31:13.8704155 to 22:36:12.0885975 UTC; 298.1803579 seconds command time). Its
actual 26-family output records Build POSIX `(3,0)`, Windows unpaired `(0,1)` and filesystem-root
encoder `(1,0)`. The `demo/` command passes its own 165 tests in 1.46 seconds and all 3,819 included
core tests in 253.60 seconds, parent zero (22:31:13.8704155 to 22:36:32.8351282 UTC;
318.9270277 seconds command time). All four static commands pass on the final source snapshot.
Both full runs report the actual 26 conditional families, 62 supported rows and 21 explicit refusals:
Build POSIX `(3,0)`, Windows unpaired `(0,1)` and root encoder `(1,0)`. Both provider-live wrappers
explicitly report that live execution was not requested; no provider, image-build or hardware acceptance
is inferred from these static gates.

Final source audit passes at 22:36:57.1662783 to 22:37:21.0455823 UTC (23.8419979 seconds,
parent zero). The frozen 903/878-file aggregates match; only the three owned Haskell files change,
while the other 900 files, all 609 fixtures, all 57 relocated bodies and old-home absence agree. Build's
210/214-line budget, exact exports, authority tail, four IOException catches and zero SomeException
occurrences agree. Only the two Main/core-test file-io edges change; all 14 private stanzas and both
project files remain exact. All 24 previous conditional declarations/helpers and the 21 Handoff hashes,
153 ordered calls, 109 physical-path arrays and 97 export-pin declarations/literal blocks are unchanged.

The canonical compiled ownership-unit measurement at 22:36:57 UTC passes (0.181164855 seconds,
parent zero), returning current Python-floor digest
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`. Process and remaining
metadata audit at 22:37:59 UTC passes (0.3645419 seconds, parent zero), retaining the original gate
container StartedAt, init and mounts without surviving test or probe children. Independent final review
confirms the sole helper-call compile correction, independent literal vectors, genuine filesystem/error
subjects and preserved authority/key/fixture controls. The engineering documents are aligned.

The sprint closes with no remaining work. The phase stays Active for its remaining sprints and own
terminal gate; closure-status documentation checks follow on the closed tree.


After closing Sprint 13.27 and advancing the table to the already Active Sprint 13.28, all 17 native
DocValidatorSpec cases pass at 22:38:45.688674 to 22:38:51.432972 UTC (5.66 seconds reported,
5.744334 seconds wall, parent zero). Phase/table harmony, current deferred evidence, governed links
and implementation citations agree.

#### Remaining Work

None.


### Sprint 13.28: Runtime activation package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`
**Production budget**: at most 400 changed nonempty lines in the existing Activation module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Define the signed activation package for one measured runtime-role entry.

Runtime deployment and complete admission recovery are owned by their consuming phases.

#### Deliverables

- `ActivationManifest` is signed per immutable pod-template revision and names every digest-addressed
  object the role reads.
- `VerifiedRuntimeRoleActivation` requires the independently installed Activation key and exact measured
  binary, wire, bundle, and runtime-instance identity.
- Verification validates both the selected and the received manifest, and compares them field by field with
  the permitted-effect rows compared as lists, so `["a,b"]` and `["a", "b"]` are different rows. Rendering is
  diagnostic only and unambiguous for comma-containing identities; keep the existing first-mismatch
  field order and earlier revision-staleness refusal.
- Activation grants no lifecycle authority until the origin-bound one-use role admission (the composition
  phase's role phase machine) consumes it.
- The service-runtime phase owns manifest installation, relayed signing consumption, deployment, and the
  live `service run` entry.

#### Validation

`ActivationSpec` retains provisioned-key verification, the dedicated signature domain, measurement
comparison, broker expiry, wire decoding and instance validation. Exact selection compares every
reachable field, including the actual permitted-effect lists, after validating the received then selected
manifest. The earlier exact revision-staleness check owns revision disagreement; no duplicate revision
mismatch row is needed. Independent literal wire/signature vectors and otherwise-valid malformed grants
establish the framing and parser contracts without a production serialization oracle.

Closure requires these `ActivationSpec` cases to exist and pass under the phase gate:

- A `validateManifest` table driven through both `signActivationManifest` and `verifyRuntimeRoleActivation`
  (received side and selected side): one row per required field set to `""` (scope, plan digest, spec digest,
  binary digest, frame, rollout revision, config digest, service identity, role-plan digest, secret channel),
  an empty effect identity, and a duplicated effect identity, each asserting `ActivationManifestInvalid` with
  that field's exact detail and callback count zero. Signing uses an otherwise valid admitted base policy;
  verification uses a genuine grant/key and matching runtime measurements, changing only the received or
  selected manifest under test. A valid base case reaches its callback once. Preserve received-manifest
  validation before selected-manifest validation, then instance/revision checks and ordered comparison.
- `activationSigningPolicy` refuses `[]` ("the signing policy is empty"), `[baseManifest, baseManifest]`
  ("the signing policy contains a duplicate manifest"), and a list holding one invalid member (that member's
  `validateManifest` detail).
- The exact-selection case is table-driven over every compared field except revision (caught earlier as
  `ActivationRevisionStale`). A genuine policy admits the base and variant; sign the variant and first verify
  it against itself with matching binary/config/secret measurements. Then change only the selected manifest
  to `baseManifest` and assert the exact `ActivationManifestMismatch` field and signed/selected values,
  with callback zero. One row selects `["read,write"]` against a signed `["read", "write"]` and asserts the
  `"permitted effects"` mismatch. Retain the exact earlier revision-staleness case rather than forcing an
  unreachable revision-mismatch branch.
- The effect-row framing case also compares `["read,write"]` with `["read", "write"]`, and pins
  `renderActivationManifest baseManifest` against a literal SHA-256 hex digest.
- The external-signing helper uses literal domain/framing bytes and a literal manifest vector, with no
  production `frameWire` or `renderActivationManifest` oracle. A fixed literal signature for seed 97 over
  that vector verifies. Pin the rendered-manifest digest and signature as independently measured literals,
  rather than computing expected values from the current implementation during the test.
- The secret-digest decoder refuses `Text.replicate 63 "a"`, `Text.replicate 65 "a"`, `""`, and
  `Text.replicate 64 "g"`; the positive control `manifestWireWithSecretDigest (activationSecretDigestText
  baseSecretDigest) baseManifest @?= renderActivationManifest baseManifest` holds; and
  `activationSecretDigestText baseSecretDigest` equals the SHA-256 hex of `baseSecretBundle`.
- "A genuine activation verifies and exposes its bound package" asserts all eleven
  `VerifiedRuntimeRoleActivation` accessors against `baseManifest`'s distinct field values.
- Verification with `adoptRelayedActivationGrant ""` and with a 63-byte adopted grant reaches the real
  `CryptoFailed` parser branch and returns exact `ActivationSignatureInvalid` parse-failure details, with
  callback zero and every other package/key/measurement input valid. Keep both direct package cases.

The separate truncated installed `activation.sig` integration case belongs to Sprint 22.3's immutable
revision opener. This sprint proves the activation-package parser directly and introduces no installation,
deployment, or service-entry dependency.

On 2026-11-01, the frozen production adoption changes 25 nonempty
lines (26 physical) in Activation only. Selected-manifest validation follows received-manifest validation
before unchanged instance/revision checks. Actual effect-list inequality decides its mismatch, with
unambiguous list rendering only in diagnostics; prefix-field order, effects then secret-channel order,
and the earlier ActivationRevisionStale check are preserved. The duplicate unreachable revision row is
absent. Public exports, representations, roles, encoders, keys, broker/signing producers, error rendering
and hash helpers remain unchanged. Independent production/doc review and final test evidence follow.

An independent ordinary-DATA Python construction fixes the explicit 12-field manifest using unsigned-64
big-endian framing, including separately framed effects and the independently hashed fixture bundle.
The manifest is 310 bytes with digest
`22bfd7a1531c8d361ab705b72ee47fd6f803d2d01837af99f2b4287496dae78c`; the 353-byte domain/framed
signing material has digest `2bc609b6ac520ba1bc7149866b1fee98047e1c302f39026fda25ab8cc8a1567e`.
Separate installed OpenSSL signs the explicit material with fixture seed 97 at 22:41:26.248627 to
22:41:26.432370 UTC (0.1837445 seconds, parent zero, empty stderr), yielding literal 64-byte signature
`45d2d324efd232f4e1014a699303f01ad5d59349bea54d9fa3fbd42abbce8b31259798ae333d7f48174517b228d0b67a22faded32eaf3c662d210d3f66160d0d`.
No production codec, hash or signer computes these expectations. The fixture bundle's independent digest
is `f1bed3729e696205449afb907fcb46d94006b00e6eab4076d4c1370febd91a1b`. These are DATA vectors;
the current-Main probe below accepts the matching positive before either malformed-grant refusal is
counted. Native `core/` `cabal build all` passes at 22:41:49.496650 to
22:42:01.564680 UTC (12.068106 seconds, parent zero, normal warning policy), recompiling Activation
and its consumers and linking the executable. Independent reciprocal reviews confirm the exact 25/26-line
production delta, preserved public/authority/codec/signing subjects and aligned 13-line lifecycle document.
The actual updated-Main public-only probe compiles at 22:43:47.355368 to 22:43:48.926043 UTC
(1.570689 seconds, parent zero, empty stderr, -Wall/-Werror) and runs at 22:43:48.926093 to
22:43:49.220862 UTC (0.294781 seconds, parent zero, empty stderr). The independently fixed 310-byte
Production manifest and 64-byte OpenSSL grant reach verification successfully with callback one. Both
an empty adopted grant and a 63-byte adopted grant return exact
`ActivationSignatureInvalid "CryptoError_SecretKeyStructureInvalid"`, callback zero, while all other
key/store/manifest/measurement inputs remain valid. Actual package database arguments expose current
Main only, with no test or private component. Test construction now adopts those measured details.

The early Linux production-only sync copies the frozen Activation source and retains the previously
validated ActivationSpec baseline. Other 901 baseline Haskell subjects and all Cabal/project metadata
match. The exact `core/` `cabal build all` preflight passes at 22:44:33.8780549 to 22:44:54.6759255
UTC (20.7565628 seconds, parent zero), compiling Activation and its consumers and linking the executable.
No test source is copied or test gate run during this preflight; final focused/full-suite evidence follows.

The test adoption changes 204 nonempty lines (208 physical), retaining all 35 existing labels and
adding five for 40 direct cases. Twelve invalid-manifest rows each exercise signing, received verification
and selected verification (36 exact refusal observations), with an actual valid control. Policy rows,
received/selected/instance precedence, eleven matching-first exact selection rows, all eleven accessors,
secret decoder lengths/characters, comma-split framing and the independent literals complete the package
contract. The scope-selection variant is descriptive DATA explicitly admitted by the genuine Production
broker policy; it does not claim a Harness-run authority. Existing broker/key/lifetime fixtures and all
installed-revision bodies remain byte-identical. The external signer alone replaces its production
framing/rendering oracle with literal domain/header/manifest bytes and the OpenSSL signature expectation.

The first native test-target build stops at 22:47:02.635526 to 22:47:43.493116 UTC (40.857850
seconds, parent one): the new secret accessor assertion compares its public Text result with an opaque
ActivationSecretDigest expectation. Review independently identified the same mismatch. The correction
uses activationSecretDigestText only on that expected value, preserving the public accessor and assertion.
No failure is completion evidence. The corrected test-target build compiles and links at
22:48:32.124692 to 22:48:46.143021 UTC (14.018420 seconds, parent zero, normal warning policy).
Independent final review confirms that one expected-value projection is the only correction, all literal
bytes/signatures and exact tables agree, all 35 prior labels remain, and the installed group and existing
broker/identity/lifetime helpers are byte-identical.

All 40 actual ActivationSpec cases pass on native Windows at 22:49:22.331143 to 22:49:23.083389
UTC (0.71 seconds reported, 0.752254 seconds wall, parent zero). Actual test-tree enumeration finds
1,025 selected cases across Activation, Handoff, indexed-plan/declaration, public compiler boundaries
and documentation. All 1,025 pass at 22:49:23.083894 to 22:52:25.128002 UTC (181.94 seconds
reported, 182.045261 seconds wall, parent zero): 40 Activation, 137 Handoff, 109 indexed-plan/declaration,
722 public compiler boundaries and 17 documentation. The complete four-command Linux static gate is
authorized only after this full focused pass.

Final synchronization matches the frozen production and corrected tests. Exactly those two Haskell files
change from the sprint baseline; the other 901 sources, all 609 fixtures, 56 other relocated bodies,
all 57 old-home absences, metadata and all 97 export-pin declaration blocks remain unchanged. The dated
903-file sorted relative-path/SHA aggregate is
`f3708fb2fc208ee17b1dacd92a4b5d2813fd39563717dae9cc23fda3f12f1f74`; the owned 878-file aggregate
is `b85ca7c452eb057b57a3ecb71e294b528717a265e34c44e6bb242bc7736c6916`. Latest governed documents
are synchronized. No production preflight is repeated after this test-only sync; the complete four-command
gate waits for the focused pass. These aggregates record this snapshot without changing any source-freeze
expectation.

All four final Linux commands launch at 22:53:01 UTC after latest governed-document verification.
Python check_code passes (0.7624054 seconds, parent zero); the unfiltered supported test_all runner
passes 376 tests in 5.83 seconds (6.874583 seconds command time, parent zero), with 100% statement
and branch coverage, no misses or partial branches. Standalone core cabal test all passes all 3,824 tests
in 246.36 seconds, Cabal PASS and parent zero (22:53:01.0403782 to 22:58:07.2180411 UTC;
306.1423978 seconds command time). The demo command passes its own 165 tests in 1.50 seconds and
all 3,824 included core tests in 247.41 seconds, parent zero (22:53:01.0308668 to 22:58:18.5500806
UTC; 317.4837405 seconds command time). Both provider-live wrappers explicitly report that live execution
was not requested. All four static commands pass; no deployment, provider or hardware acceptance is
inferred. Both complete runs report 26 conditional families, 62 supported rows and 21 explicit refusals.

Final source audit passes at 22:58:37.6809117 to 22:59:00.0297459 UTC (22.3142598 seconds,
parent zero). Frozen 903/878-file aggregates match. Exactly Activation and ActivationSpec change;
other 901 sources, all 609 fixtures, other 56 relocated bodies and all 57 old-home absences remain
exact. Production/test budgets are 25/26 and 204/208; exports, signing/codec/error bytes, earlier
revision refusal and metadata are preserved. All 97 export-pin declarations/literal blocks, 21 Handoff
hashes, 153 ordered calls, 109 physical-path arrays, owned response bytes and all 26 conditional-family
declarations remain unchanged.

The canonical compiled ownership-unit measurement at 22:58:37 UTC passes (0.183264078 seconds,
parent zero), returning current Python-floor digest
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`. Process and remaining
metadata audit at 22:59:12 to 22:59:13 UTC passes (0.3752238 seconds, parent zero), retaining the
original gate container StartedAt, init and mounts without surviving test/probe children. The lifecycle
document and exact package-boundary description agree with the verified implementation.

The sprint closes with no remaining work. The phase stays Active for its other sprints and own terminal
gate; closure-status documentation checks follow on the closed tree.


After closing Sprint 13.28 and advancing the table to the already Active Sprint 13.29, all 17 native
DocValidatorSpec cases pass at 22:59:45.503715 to 22:59:51.547609 UTC (5.97 seconds reported,
6.043931 seconds wall, parent zero). Phase/table harmony, current deferred evidence, governed links
and implementation citations agree.

#### Remaining Work

None.


### Sprint 13.29: Registered one-use edge [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: Handoff and its existing private Internal owner only, within the three-module and
400-changed-nonempty-line cap; no new authority representation or public helper
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`, `DEVELOPMENT_PLAN/rationale.md`

#### Objective

Make edge registration root-owned and relaying strictly weaker than signing.

#### Deliverables

- Root-owned `registerHandoffEdge` mints a one-use token for an exact canonical binding; the admitted
  registration companion evaluates its actual plan predicate before the shared durable registration.
  Existing recoverable registration retains its separately admitted behavior.
- Registration publishes the planned binding under the store's exclusive entry before a grant can
  consume it. A rejected admitted registration returns its original rejection and creates no edge.
- `grantHandoff` checks the live broker and exact registered binding, then answers for its transcript.
  The plan predicate belongs to admitted registration; it is not rerun by grant issuance.
- Tagged planned and granted records distinguish an unconsumed binding from its settled transcript.
  Exact-version compare-and-swap gives one durable first grant, makes an identical retry deterministic,
  and refuses a different retained transcript/record as consumed.
- A failed first-grant write followed by the exact unchanged planned record or an absent row retains
  the original `HandoffStoreFailure`. The exact granted bytes succeed; a foreign retained row is
  `HandoffTokenConsumed`; a failed reread retains that read failure.
- One pure total DATA policy in the existing private Internal module classifies those five reread
  outcomes and has Handoff as its sole production consumer. It has no store handle, authority value,
  writer, injected validator or callback, and creates no public facade route or import cycle.
- Broker consistency checks retain project, scope, store, generation and verb. The grant signature keeps
  offer and broker on one nominal generation; descriptive wire-route mismatches are checked before a
  corresponding relay/offer can be admitted.

#### Validation

Preserve root registration, unregistered-edge refusal, retry/reuse, distinct ordinary registrations,
cross-edge isolation and broker-lifetime controls. Direct `verifyHandoff` is pure and has no store, so it
cannot exercise consumption. The existing isolation case is named "granting one edge does not consume
another edge's token" to match the actual two-grant behavior it tests.

Exercise the real private pure policy with all five complete outcomes after a failed CAS: exact granted
bytes yield success; exact planned bytes and absence yield the original write error; a different retained
row yields consumed; a typed reread failure yields that actual failure. Handoff maps the policy result to
its existing errors after the actual CAS/read. A source/visibility control requires one private definition,
one production consumer and no public export, constructor-based authority or injected store failure.

For rejected admission, first build an independently valid prospective offer for the same binding input
using the existing fresh-token, binding, relay and offer producers, without registering it. Capture the
actual protected image after legitimate root setup. A counted rejecting `registerAdmittedHandoffEdge`
callback must return exactly `Right (Left reason)` once and leave that image unchanged; granting the
prospective unregistered offer then yields exactly `HandoffEdgeUnregistered`, also without mutation.
The rejected call returns no relay/token, so it does not mint a binding that can subsequently be granted.
Do not pre-register the candidate or call the registering `newOfferWith` helper for this negative.

An offer from a genuinely different broker generation cannot be passed to `grantHandoff`'s required
same-generation broker without violating its nominal type. A genuine root from another store also carries
its own generation; a broker with a store different from its held root authority is refused before its
callback. Keep these actual static and broker-construction boundaries, with measured direct cross-index
grant refusals and matching same-index positives, rather than adding casts or a new authority producer.
A runtime verb backstop can use the existing private root-invocation validator with one actual allocated
epoch/session/principal to obtain two independently checked verbs under that epoch, then call the real
broker/grant route. Release the protected entry after obtaining those real checked roots and before
calling the broker/grant API, which takes its own protected entry. State that lower-kernel fixture scope
accurately; it does not prove ordinary
`withProductionRoot` admits another verb. Require the exact existing verb-mismatch detail and a matching
positive. Raw route-origin refusal cases belong to the keyless duplex relay foundation, not to a fictitious
well-typed foreign-generation/store grant.

The concurrent identical-request case calls the actual API in two threads, observes both `Right` grants
and identical signatures, and reads the real selected token row at successor version two. A further exact
retry preserves full bytes/version, and a conflicting challenge is refused. Use bounded readiness/start
coordination and cleanup so child exceptions cannot hang the suite. The broker lifetime MVar and protected
entry serialize this path: it proves concurrent-request convergence and deterministic replay, not an
artificially forced competing-CAS interleaving. The pure classification matrix covers the failed-CAS policy
without a fabricated writer. Preserve actual one-use callbacks/results and complete protected-state checks.

Any affected HandoffSpec freeze remains scoped to the definitions the frozen boundary actually owns.
Preserve the fixed five ordered Aeson declaration bundles, owned response-authentication bytes and all
capability, producer, import, role, strictness, order, redaction and wire controls. Existing whole-Internal
hashes or shared whole-Handoff line arithmetic are not rebased to current files or adjusted by subtracting
this unrelated policy's lines; retain legitimate capability-owned declaration subjects and keep historical
landing budgets as dated evidence. Run the focused runtime/type/private-policy controls and all four host
static commands on the coherent final tree, recording actual results.

On 2026-11-01, the frozen production change is 41 nonempty lines (44 physical) in two modules:
Handoff 17/17 and Internal 24/27. The generic private DATA classifier takes only planned/granted bytes,
the original write failure and the actual reread's bytes/error result. Handoff alone consumes it in
production after the actual failed CAS and reread, mapping its descriptive result to the existing
errors. Exact granted bytes succeed; planned bytes or absence retain the original write error; a foreign
row is consumed; a reread error retains that error. Public Handoff exports, existing signing-capability
declarations/bodies, the actual CAS/version/key, planned/granted encodings and dependency rows are exact.

The capability freeze is measured from the saved sprint baseline with the actual SourceGuard readers,
using all 99 current core-test compiler arguments unchanged and only external helper/target/output
additions. Compilation passes at 23:03:14.235273 to 23:03:17.565849 UTC (3.330596 seconds, zero,
empty stderr); measurement passes at 23:03:17.565907 to 23:03:17.625355 UTC (0.059457 seconds,
zero, empty stderr). The retained typed section has 65 tokens; complete clauses for recoverySigningKernel,
consumeRecoverySigningKernel and consumeRootedLifecycleResponseSigningKernel have three, five and five
tokens. Their ordered Aeson tuple is 1,121 bytes with saved-baseline digest
`78fee3610ada63f9c2c38a8a07589c152e9a90824bbf16fed2ce5f5af5001954`. Current typed tokens,
complete clauses, bytes and digest agree; the unrelated whole Internal module correctly differs.
Source/build-info/metadata hashes and mtimes remain unchanged during this ordinary DATA experiment.

Only the three affected rooted-response/pairing/relay freezes adopt that capability-owned baseline
bundle. Its owners retain their statuses and other runtime work; Rooted's 757-line evidence and digest,
the owned response's 119 lines/6,323 bytes/fixed digest, the five Handoff bundles and every independent
semantic/capability/type/import/producer/order/wire control remain. Whole-Internal hashes and its old
25-line count become dated attribution; no current whole-file hash, subtraction or complement replaces
them. The exact owners' narrative and existing rationale describe this scope and retain the independent
13-reader/26-line checks.

Native core cabal build all passes at 23:03:42.717590 to 23:03:54.546247 UTC (11.828724 seconds,
parent zero, normal warning policy), rebuilding the changed private modules and executable consumers.
The actual official public-Main compiler context then accepts the same-generation grant control with
exit zero and empty stderr at 23:04:43.715940 to 23:04:43.881682 UTC (0.165742 seconds). The
otherwise unchanged foreign-generation fixture immediately fails with exit one in 0.144754 seconds,
GHC-25897 at 11:47: brokerGenerationB cannot match brokerGenerationA, with expected HandoffOffer scope
brokerGenerationA and actual HandoffOffer scope brokerGenerationB. The strict existing matcher registers
that measured phrase. An initial negative/positive pair observed the same intended results; the pair is
repeated positive-first without source or context changes. No missing import or private-unit refusal
satisfies this proof. The new fixture is 415 bytes, nine nonempty/eleven physical lines; all prior compiler
subjects remain unchanged.

The following genuine runtime fixtures, scoped test adoption and complete validation establish this
registered-edge contract. They make no process-deployment or hardware acceptance claim.

The Linux production-only sync passes at 23:07:10.117899 to 23:07:11.378438 UTC (1.260538
seconds, parent zero), copying only the two frozen production modules and current governed documents.
Other 901 baseline Haskell files, all baseline test sources and Cabal/project metadata remain exact;
the new compiler fixture is not copied during this production-only step. Independent production review
confirms the generic total DATA policy, actual failed-CAS/reread mapping and unchanged signing/wire/API
subjects. Exact core cabal build all passes at 23:07:13.8724164 to 23:07:28.6841422 UTC
(14.7770942 seconds, parent zero), recompiling affected private/Main consumers and linking the executable.
No focused or full test gate runs before the coherent final test freeze.

Final HandoffSpec adoption changes 308 nonempty lines (311 physical), retaining all 137 prior cases
except the required isolation-label correction and adding four cases. The five typed DATA outcomes keep
distinct write/read error provenance. A genuine prospective unregistered offer and counted rejecting
admission preserve the full protected image; the same-epoch checked-kernel verb fixture returns a closed
IO action only after both protected/authority result layers are forced outside the entry. Concurrent
identical requests use bounded readiness/start/result coordination, forkFinally and bracket cleanup;
the actual selected token row moves from version one/planned bytes to version two/granted bytes.
Exact retry preserves full keys/bytes/versions and signature, while a conflicting challenge is exactly
consumed without mutation. This proves serialized convergence, not a forced competing-CAS race.

Independent final review confirms the exact saved capability bundle, all unaffected hashes, five existing
Handoff wrapper bundles, physical-path order, protocol/config runtime cases, Rooted757 and owned response
bytes. Only the three approved Internal hashes adopt their owned bundle; the old private-module count is
dated. Compiler tests plus the new fixture add 37 nonempty/40 physical lines; combined test delta is
345 nonempty/351 physical lines, with all 609 prior fixture bytes and exactly 610 unique registrations.
The matching-index generated source is byte-identical to its measured positive control. Compiler and
binary-context documentation changes receive independent review with no further concern.

Native test-target compilation passes at 23:13:46.503954 to 23:14:10.892439 UTC (24.388623
seconds, parent zero, normal warning policy). The frozen HandoffSpec hash is unchanged before/after the
build. Actual test enumeration selects 991 cases: 141 Handoff, 724 public compiler boundaries, 109
indexed-plan/declaration and 17 documentation. All 991 pass at 23:15:10.279740 to 23:18:07.889194
UTC (177.51 seconds reported, 177.610465 seconds wall, parent zero), including the genuine admission,
checked-kernel verb, concurrent/retry state and private-policy controls. The four-command Linux static
gate is authorized after this complete focused pass.

Final synchronization passes at 23:15:54.531214 to 23:16:08.322492 UTC (13.791279 seconds,
parent zero). Native and Linux agree across 904 Haskell files with dated aggregate
`64bc4a07626fc3aeecb37955b4e8d44ac5e3b2be3408e51c97c3184fc73e9c82`; the owned 879-file
aggregate is `877af37ddbded9c82c783ae4b5051c9e739f33cb90d235b12c7f8c6a6c656a48`. Independent
native recomputation agrees. Four original sources change and one fixture is new; the other 899 sources,
all 609 original fixtures, 55 other relocated bodies and all 57 old-home absences match. Metadata and
97 export-pin blocks remain exact; Handoff hashes change only in the three authorized capability subjects,
with physical-path arrays, owned response/Relay sections and reader controls retained. These snapshot
aggregates are dated sync measurements, not new shared-file expectations. An additional importer audit
finds no affected authority allow-list: its independent inventories scan library/production sources,
while the new lower-kernel fixture is confined to test source.

All four Linux commands launch at 23:18:42 UTC after latest governed-document synchronization.
Python check_code passes (1.5421802 seconds, parent zero); unfiltered supported test_all passes 376
tests in 6.14 seconds (7.8756326 seconds command time, parent zero), with 1,585 statements, 460 branches,
zero misses/partial branches and 100% coverage. Standalone core cabal test all passes all 3,830 tests
in 281.59 seconds, Cabal PASS and parent zero (23:18:42.028184 to 23:23:56.350748 UTC;
314.284136 seconds command time). Demo passes its own 165 tests in 1.75 seconds and all 3,830 included
core tests in 281.95 seconds, both Cabal PASS and parent zero (ending 23:24:09.072844 UTC;
327.006197 seconds command time). Both provider-live wrappers explicitly report that live execution is
not requested; no provider, process-deployment or hardware acceptance is inferred. All four commands pass;
final source/fixture/frozen-control audit passes at 23:24:57.331470 to 23:25:17.430705 UTC
(20.0576828 seconds, parent zero). Both final aggregates match. Exactly four originals and the new fixture
change; other 899 sources, all 609 original fixture bytes, 55 other relocated bodies and all 57 old-home
absences remain exact. All 610 fixtures, metadata and 97 export-pin blocks agree. Only the three permitted
Internal hash occurrences adopt the measured capability bundle; all other hashes, all 153 original ordered
requirement arrays plus one new policy array, 109 path arrays and owned response/Relay/readers remain.

The canonical compiled ownership-unit measurement at 23:24:57 UTC passes (0.206685 seconds, parent
zero, empty stderr), returning current Python-floor digest
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`. Process/remaining metadata
audit passes at 23:25:12.209186 to 23:25:12.671027 UTC (0.422818 seconds, parent zero): original
container StartedAt, init and both mounts remain, without surviving test/probe children. Both full suites
report the actual 26 conditional families, 62 supported rows and 21 refusals, including root encoder
`(1,0)`, POSIX native names `(3,0)` and Windows unpaired names `(0,1)`. Governed documents and the
capability-owned freeze rationale agree with the verified source and fixed baseline evidence.

The sprint closes with 41/44 production lines across two modules, 345/351 test lines and no remaining
work. The phase stays Active for its other sprints and own terminal gate; closure-status documentation
checks follow on the closed tree.


After closing Sprint 13.29 and advancing the table to the already Active Sprint 13.30, all 17 native
DocValidatorSpec cases pass at 23:25:59.734082 to 23:26:05.525702 UTC (5.71 seconds reported,
5.791654 seconds wall, parent zero). Phase/table harmony, current deferred evidence, owned-freeze
rationale, governed links and implementation citations agree.

#### Remaining Work

None.


### Sprint 13.30: Keyless duplex relay foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportHandoffRelay.hs`
**Production budget**: Handoff and Relay only, within the three-module and
400-changed-nonempty-line cap; Protocol and Receiver retain their existing implementations
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Let an admitted nested frame reach root-owned handoff services through a structurally keyless link. The
per-link capability sets of the root coordinator links `rootForwardBrokerLink` and `rootReverseBrokerLink`
belong to the recursive lifecycle command phase, which owns those coordinator shapes and the config-open
restriction on the forward link; this sprint documents only that they are key-backed.

#### Deliverables

- `BrokerLink` is the private route to root-owned edge open/grant, activation signing and recovery-wire
  signing services.
- Root-backed links retain live brokers and admission predicates; the relayed link retains only its
  authenticated route, request identity, installed-key digest and actual duplex channel. It has no signing
  key or root-store authority.
- `offerHandoffEdge` opens a narrowed-project-config edge through that link, performs the child exchange,
  and serves admitted relay requests until completion/refusal. Recovery-kind input is refused there;
  the existing reverse-descent opener owns recovery edges.
- `brokerRelayFromRouteWire` checks all five authenticated-route coordinates and all seven supplied
  opening-request coordinates before constructing its relay. Each exact mismatch has a specific refusal.
- An admitted child raises only the closed request tags allowed in `ChildRunning`, and replies retain
  the same exact request identity and authenticated requester path.
- The one shared exact-offer decoder refuses bytes after its three frames with the actual
  `HandoffWireTrailingBytes` category through both callers. A real rooted-signing request exercises that
  branch before any signer is reached and returns the matching peer refusal.
- Actual channel-loss controls distinguish a failed route before root mutation from an exact request
  retried through a fresh legitimate route to the same still-live root after its durable grant. Replay
  preserves that request's deterministic result and settled token row; this does not claim automatic
  reconnection or replay after the root lifetime has ended.

#### Validation

Preserve the private route, request/response ownership, keyless import graph, payload bounds and all
existing broker-lifetime controls. `ImportHandoffRelay.hs` continues to refuse in the official Main-only
context, with its measured private-unit ownership; tests use the shared real private route. Existing
lexical guards and direct expired-broker controls are not runtime evidence of a severed duplex route.
Dated evidence on 2026-08-08 (aarch64-osx, GHC 9.12.4): the library built with `-Werror`, the Phase 13
exact-diagnostic matrix passed 87/87, the focused severed-route regression passed 1/1, and
`cabal test all --ghc-options=-Werror` passed 1626/1626 cases. Retain those dated outcomes without presenting
them as a run of the newly required tests.

Starting from an actual valid rendered binding and its real authenticated route, require a matching
`brokerRelayFromRouteWire` positive and twelve otherwise well-formed exact refusal rows. Five change the
route comparison subject (installed project, scope, protected store, broker generation and verb); seven
change the corresponding `Just input` comparison subject (specification digest, payload kind, plan
revision, parent frame, child frame, child config digest and phase). Raw descriptive byte mutations stay
canonically framed/decodable and preserve earlier subjects; they do not construct an opaque authority or
cast nominal indices. Each row requires exactly `HandoffBindingMismatch` with
`"the relayed binding's <field> does not match its authenticated route or opening request"`, using that
actual field spelling. Keep the `Nothing` opening-input positive and do not let a malformed decoder input
mask a coordinate refusal.

For the trailing-offer case, run the real parent `offerHandoffEdge` and child protocol over actual binary
handles, completing the genuine admitted outer exchange first. Send a `RecoveryRequestTag` with a
canonical rooted-signing header naming the kind of an otherwise valid exact offer, and append a known
nonzero byte count after that offer's payload/token/binding frames. A config-kind offer/header can exercise
the real rooted-signing `Just kind` arm without depending on later recovery-package integration. The
parent returns exactly `Left (RelayHandoffFailure (HandoffWireTrailingBytes n))`, where n is the actual
appended byte count; the peer receives `RefusedTag` with code `unauthenticated`. The constructor-level
`RelayRefusedByPeer` assertion must run the actual receiving Relay consumer, including its own await/refusal
mapping: use the genuine ReceivedEdge, `withConfigBrokerLink`, and nested `offerHandoffEdge` route. A raw
Protocol peer may assert only the observed tag/code/detail fields and cannot manufacture that Relay error.
A wire proxy may change only the offer trailing bytes; it supplies no authority or signer. Keep request identity, admitted requester path, payload kind, token and binding valid,
and demonstrate the unchanged non-trailing control reaches the intended route. The ordinary recovery-fields
`Right Nothing` arm does not adopt that offer and cannot prove this branch. No new export of
`adoptRelayedOffer`, copied protocol implementation, injected signer or fabricated authority is allowed.

Use real connected handles and genuine admitted root/relay values for route-loss controls. Sever the
upstream route before a relayed open/grant reaches its root and require the actual typed protocol/relay
failure with the exact measured constructor and cause for that loss point, uncalled root admission/effect
continuation and unchanged root protected image after setup. An arbitrary `Left` is insufficient.
Separately complete an actual selected grant, sever its channel, establish a fresh legitimate route while
the same root broker is still live, and retry that same offer/challenge. Compare the actual response bytes
and complete selected token record/version with the first success, observing that it is not consumed a
second time. Capture images after each legitimate route setup so setup writes cannot masquerade as request
writes. Bound waits, observe both peer/thread results, and bracket handles/threads on success, refusal and
exception. A direct `grantHandoff` retry alone, a source substring, or an expired-broker result does not
replace this actual duplex evidence.

The payload Haddock guard reads the documentation scope of `offerHandoffEdge ::` through its first equation
and requires "the exact narrowed project config bytes", not "recovery-adapter bytes". Documentation
assertions remain separate from executable-token proofs. Preserve the sender-side bound section from
`maxEmbeddedOfferPayloadBytes :: Int` through `awaitChallenge ::` and all of its real ordered fragments
when moving the constant above the function Haddock. Preserve the corrected request/provider-package
Haddock subjects. The Handoff facade has five structured Aeson name/clause/token bundle hashes
(request, response, relay, scope, carrier) plus one owned raw response-authentication section of 119
significant lines / 6,323 bytes. Keep those six Handoff subjects and their unchanged constants, and retain
the separate private Internal signing-capability bundle unchanged. Do not resurrect an obsolete
whole-Handoff hash or count the separate capability bundle as a sixth Handoff wrapper bundle.

Run these runtime and source/metadata boundaries, the real official private-import compiler subject,
ProjectPlanSpec and DocValidatorSpec, then all four host static commands on the coherent final tree.
Record actual counts, platform behavior and precise diagnostics; the phase's own declared Gate remains
required at phase closure.

On 2026-11-01, the frozen production adoption changes 28 nonempty lines (31 physical) in two modules:
Handoff 3/3 and Relay 25/28. Handoff changes only the provider/recovery request Haddocks. Relay's only
executable change preserves RelayHandoffFailure(HandoffWireTrailingBytes actualTrailingLength) in the
shared exact-offer decoder; its other edits correct config-only payload documentation, constant/Haddock
attachment and root-backed versus sole keyless-link descriptions. No API, representation, import or
dependency changes. Independent production review agrees with the applied source.

The five Handoff declaration bundles remain exact. Internal, Protocol and Receiver raw bytes are
unchanged, including the fixed signing-capability bundle. Owned response bytes remain 6,323 with the
fixed 119-line subject/digest. The three Relay transport slices independently retain their saved
1,778/3,438/2,514-byte contents and concatenated digest. Sender-bound executable tokens and ordered
fragments remain; moving the constant changes only its documentation attachment. No shared-file or
owned-subject hash is rebased.

Native core cabal build all passes at 23:28:26.657983 to 23:28:40.372610 UTC (13.714705 seconds,
parent zero, normal warning policy), compiling affected private/Main consumers and linking the executable.
The Linux production-only sync passes at 23:29:17.365215 to 23:29:18.871655 UTC (1.506437 seconds,
parent zero), copying only the two frozen modules and governed documents. Other 902 baseline Haskell
sources, baseline tests/610 fixtures and Cabal/project metadata remain exact. Exact core cabal build all
passes at 23:29:21.8969931 to 23:29:40.7440651 UTC (18.811873 seconds, parent zero), compiling and
linking the Linux consumers. No test gate runs during either library preflight.

The genuine duplex fixture in HandoffSpec is measured through an authorized external wrapper compiled
from the actual staged source and current test component arguments, retaining existing four-module
thinning without copied production protocol logic or new private visibility. Unmodified positive routes
precede observed loss/peer results. Final assertions use those actual outcomes; no arbitrary refusal is
counted as passing evidence.

The actual staged-source diagnostic wrapper retains all 99 current test compiler arguments and the
existing four-module thinning. Its initial invocation stops before source compilation at 23:32:39.405993
to 23:32:39.576692 UTC (0.170700 seconds, parent one): -Wmissing-home-modules requires the real
Expect, Fixture and SourceGuard targets that Cabal supplies separately from compiler-args. Appending
those existing source targets fixes the invocation without suppressing warnings or changing visibility;
compilation passes at 23:33:01.782505 to 23:33:35.039283 UTC (33.256968 seconds, zero, empty stderr).
Review then bounds the entire fresh receive/replay action before its first blocking read. The changed
source recompiles at 23:34:41.108886 to 23:34:59.717261 UTC (18.608481 seconds, zero, empty stderr)
into Temp-only outputs before any diagnostic execution; source hashes identify each executable.

All three real sequential diagnostic cases pass against the final source, with empty stderr and parent
zero: unmodified-then-trailing at 23:35:15.565726 to 23:35:15.714835 UTC (0.11 seconds reported,
0.149110 seconds wall); loss before action at 23:35:15.714898 to 23:35:15.774194 UTC (0.04 /
0.059299 seconds); fresh-route exact replay at 23:35:15.774250 to 23:35:15.870933 UTC (0.08 /
0.096687 seconds). The parent produces exact RelayHandoffFailure(HandoffWireTrailingBytes 3),
the genuine nested Relay await produces RelayRefusedByPeer with unauthenticated code, and the cut-route
cause is exact RelayProtocolFailure(ProtocolTruncated 8 0). Observed results, admission/callback counts,
postsetup complete images, encoded response equality and selected row/version establish each claim;
no direct broker retry, raw-peer-only error, expired-root stand-in or arbitrary Left substitutes.

Final HandoffSpec adoption changes 369 nonempty lines (386 physical), adding five cases. Exact rollback
of the new group/helpers/import additions restores the saved test baseline byte-for-byte; all 141 old
labels, hash multiplicities, ordered guards, physical-path arrays and runtime/frozen bodies remain exact.
Independent final review confirms real root/activation/Receiver lifetimes, payload-only proxy mutation,
actual nested refusal mapping, before-action no-write and same-live-root wire replay. Every worker and
both pipe-pair brackets are observed/cleaned on success, refusal and exception; all blocking replay reads
are inside the whole-action bound.

The native test-target build passes at 23:36:54.938474 to 23:37:18.129758 UTC (23.191414 seconds,
parent zero, normal warning policy), with the final source hash unchanged before/after compilation. All
five new relay cases pass at 23:37:59.471973 to 23:37:59.876141 UTC (0.30 seconds reported,
0.404175 seconds wall, parent zero), including the twelve exact route rows and documentation/bound
controls. Actual test-tree enumeration selects 996 focused cases. All pass at 23:37:59.876799 to
23:40:58.916767 UTC (178.93 seconds reported, 179.040993 seconds wall, parent zero): 146 Handoff,
724 public compiler boundaries, 109 indexed-plan/declaration and 17 documentation cases. The complete
four-command Linux gate is authorized only after this full focused pass.

Final synchronization passes at 23:38:52.707262 to 23:39:05.129443 UTC (12.422180 seconds, parent
zero). All 904 Haskell files match native/Linux with dated aggregate
`46d357bbeb8354b57b8fcab2c0d531497863935934a4a9d00e0f904e8a844d3c`; the owned 879-file aggregate
is `8e1fd287602265b49a638c572db307dffbe3c472012ffcc0d1eded4a405f2533`. Exactly Handoff, Relay and
HandoffSpec change; the other 901 files, all 610 fixtures, 55 other relocated bodies and all 57 old-home
absences remain exact. Metadata and 97 exports, all old fixed hashes, five Handoff bundles, separate
capability, owned response/Relay slices and 109 path arrays are unchanged. All 154 existing ordered
arrays remain byte-identical, with one new assertion array for 155 total. These aggregates measure this
snapshot; they do not replace any owned source-freeze expectation.

All four Linux static commands launch at 23:41:30.867810 UTC after latest governed-document sync.
Python check_code passes (0.7300058 seconds, parent zero); unfiltered supported test_all passes 376
tests in 5.61 seconds (6.5512292 seconds command time, parent zero), with 1,585 statements, 460 branches,
no misses/partial branches and 100% coverage. Standalone core cabal test all passes all 3,835 tests
in 244.06 seconds, Cabal PASS and parent zero (23:41:30.8678103 to 23:46:03.5120519 UTC;
272.6045907 seconds command time). Its provider-live wrapper explicitly reports that live execution is
not requested. Demo passes its own 165 tests in 1.52 seconds and all 3,835 included core tests in
246.69 seconds, both Cabal PASS and parent zero (23:41:30.8678103 to 23:46:17.8671553 UTC;
286.9598657 seconds command time). Both provider-live wrappers explicitly report that live execution is
not requested. All four commands pass; no provider, coordinator deployment or hardware acceptance is
inferred from these static gates.

Final source/fixture/frozen-control audit passes at 23:46:37.4913973 to 23:46:55.7458680 UTC
(18.2216603 seconds, parent zero). Both final aggregates match. Exactly three owned sources change;
the other 901 files, all 610 fixtures, 55 other relocated bodies and all 57 old-home absences are exact.
Metadata, 97 exports and every old fixed hash, five Handoff bundles, separate capability, owned response
and three Relay slices remain unchanged. All 154 old ordered arrays and 109 path arrays are exact,
with one new requirement array for 155 total. Both full gates report the actual 26 conditional families,
62 supported rows and 21 refusals, including root encoder `(1,0)`, POSIX names `(3,0)` and Windows
unpaired names `(0,1)`.

The canonical compiled ownership-unit measurement at 23:46:37 UTC passes (0.183066 seconds, parent
zero, empty stderr), returning current Python-floor digest
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`. Process/remaining metadata
audit passes at 23:46:54.632678 to 23:46:55.044116 UTC (0.375202 seconds, parent zero), retaining
original container StartedAt, init and mounts without surviving test/probe children. Governed binary-
context documentation and the exact scope of the real duplex observations agree with the source.

The sprint closes with 28/31 production lines in two modules, 369/386 test lines and no remaining work.
The phase stays Active for its other sprints and own terminal gate; closing-status documentation checks
follow on the closed tree.


After closing Sprint 13.30 and advancing the table to the already Active Sprint 13.31, all 17 native
DocValidatorSpec cases pass at 23:47:43.976595 to 23:47:50.661319 UTC (6.60 seconds reported,
6.684765 seconds wall, parent zero). Phase/table harmony, current deferred evidence, governed links
and implementation citations agree.

#### Remaining Work

None.


### Sprint 13.31: Closed rooted outer vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 160 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Reserve the only two protocol-v1 outer tags used by the rooted lifecycle exchange.

#### Deliverables

- `ProtocolTag` adds exactly `RootedLifecycleRequestTag` and `RootedLifecycleResponseTag` to the closed
  protocol-v1 vocabulary.
- Each rooted outer message carries exactly one bounded canonical field whose inner codec is owned by a
  later sprint in this phase.
- `ChildProtocolState` permits a rooted request only after admission reaches `ChildRunning` and moves every
  admitted request family into one exact response-waiting state.
- That state retains the sole expected response tag and exchange request identity; a second request,
  unsolicited/wrong response, duplicate, out-of-order, or post-terminal traffic refuses.
- Exact private-source guards pin every stable protocol-v1 tag byte (24 tags in the tree: this sprint's
  rooted pair, Sprint 13.41's `FrameTransactionTag`/`FrameOutcomeTag`, and the three `ProviderDependency`
  tags among them), both one-field rooted shapes, and the total
  encode/decode/field-count tables; the response-waiting transitions, including the request-identity
  comparison in `requireRequest`, are exercised by value through Sprint 13.23's test-only route, which no
  consumer package can import.

#### Validation

`HandoffSpec` pins every protocol-v1 tag byte, rooted outer field count, total encode/decode table
and state-transition call site. The existing finite DATA matrix reaches all 13 opaque states through
actual transitions, checks all 24 tags, 39 legal pairs, 585 illegal pairs and 37 request-identity mismatches
using ids 17/18. Preserve that complete matrix and its fixed requireAcknowledgement declaration bundle.
There is no separate counter/ordinal in this outer FSM: the retained Word64 is the exchange identity.
Phase 17 owns real-process rooted exercise and durable inner coordinator semantics.

Closure adds one explicit bounded connected-pipe 7/8 DATA observation. Reach the running state bound to request 7 through actual
Offer receive, Challenge send, Grant receive and Accepted send; reach the rooted response-waiting state
through the actual rooted-request send. Send and decode actual protocol messages before applying
childProtocolReceive. Expected rooted reply8 is exactly `ProtocolRequestMismatch 7 8`; reply7 resumes the
original running state bound to 7. From genuinely reached acknowledgement/held-request states, matching acknowledgement
and refusal finish, while their id8 counterparts retain the same exact identity refusal. For precedence,
acknowledgement8 with altered bytes still reports `ProtocolRequestMismatch 7 8`; matching id7 with altered bytes
reports `ProtocolAcknowledgementMismatch`, and exact id7/bytes finishes. Unsolicited, duplicate and
post-finished rooted replies remain ProtocolInvalidTransition. The initial no-held-request state accepts
a parent refusal without an identity comparison; do not change that exception or construct hidden states.
Force the bounded writer/handle results. These are connected codec/FSM DATA observations, not a new
Receiver, process, admission or coordinator claim.

Dated 2026-08-12 evidence: the combined library/test `-Werror -j1` build passed; `HandoffSpec` passed 68/68;
the public compile-fail boundary passed 452/452; `DocValidatorSpec` passed 2/2; and canonical
`cabal test all --ghc-options=-Werror -j1` passed 1913/1913. At landing `Handoff.Protocol` measured 463
significant lines, 17 above its 446-line baseline and well below this sprint's 160-line cap, with SHA-256
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`; the finite decoder/FSM work,
frame-transaction and provider-dependency tags extend that file, so the figure is this sprint's landing
measurement, not a live pin. No Cabal row, public export,
named type, runtime importer, or real-process claim was added.

On 2026-11-01, current implementation work adds one HandoffSpec case: 50 nonempty/physical lines,
no production changes. It sends and decodes fifteen actual messages through connected handles, checks
exact decoded-message equality, and applies childProtocolReceive to genuinely reached request-7 states.
The expected identity errors, acknowledgement-byte precedence, matching running/finished results,
initial refusal exception and illegal response cases are exact values. The entire finite receive loop is
bounded, with forkFinally/bracket writer cleanup and its completion forced.

Exact rollback of that single insertion restores the saved test baseline byte-for-byte. All 146 prior
labels/assertions, literal hash multiplicities, broader 13-state/24-tag/17-to-18 matrix and fixed
requireAcknowledgement bundle are unchanged. All 903 other Haskell files, including Protocol's raw
source, remain baseline-identical. Independent final review confirms the connected DATA scope and every
preserved opaque-state/codec/transition/frozen control.

Native test-target compilation passes at 23:51:29.914095 to 23:51:54.844936 UTC (24.930982
seconds, parent zero, normal warning policy), with the frozen source hash unchanged before/after the
build. The explicit connected case passes at 23:52:21.149321 to 23:52:21.252951 UTC (0.03 seconds
reported, 0.103635 seconds wall, parent zero). Actual enumeration selects 997 focused cases. All pass
at 23:52:21.253641 to 23:55:14.555355 UTC (173.22 seconds reported, 173.302708 seconds wall,
parent zero): 147 Handoff, 724 public compiler boundaries, 109 indexed-plan/declaration and 17
documentation. The four-command Linux gate is authorized only after this focused pass. No production-
library rebuild is needed for the test-only change; preceding library validation covers unchanged sources.

Final sync/audit passes at 23:53:41.655914 to 23:53:53.810511 UTC (12.154595 seconds, parent
zero). Native/Linux agree across 904 Haskell files with dated aggregate
`fa5f0369df76beac448badba069e72dddcd276480abed895b130ef7b249e392f`; the owned 879-file aggregate
is `47864f26d95ebafa1962abfae26c9fa9cb737de3c79bd927f5442907acc90611`. Only HandoffSpec changes;
all 903 other sources, 57 relocated bodies, 610 fixtures and metadata are exact. All 97 export blocks,
old fixed hashes, five Handoff bundles, separate capability, response/Relay sections, 155 existing ordered
arrays and 109 path arrays remain unchanged. Governed docs clarify the outer DATA rules and correct
both Transaction-owner descriptions to name the shared production owner and independent testing copy.
These synchronization aggregates do not become new source-freeze expectations.

All four Linux static commands launch on 2026-11-01 at approximately 23:56:58 UTC after latest
governed-document synchronization. Python check_code passes (1.3090552 seconds, parent zero);
unfiltered supported test_all passes 376 tests in 5.97 seconds (7.3788666 seconds command time,
parent zero), with 100% statement/branch coverage. Demo's own 165 cases pass in 1.43 seconds and its
provider-live wrapper explicitly reports no requested live execution. Standalone core passes all 3,836
tests in 257.42 seconds, Cabal PASS and parent zero (2026-11-01 23:56:58.0279319 to
2026-11-02 00:01:42.2205361 UTC; 284.1587019 seconds command time). Demo passes its own 165 tests
in 1.43 seconds and all 3,836 included core cases in 256.80 seconds, both PASS and parent zero
(2026-11-01 23:56:58.0136313 to 2026-11-02 00:01:40.6428554 UTC; 282.5929783 seconds command
time). Both provider-live wrappers explicitly report no requested live execution. All four static
commands pass. Final source audit passes on 2026-11-02 from 00:02:01.6191491 to
00:02:20.0511699 UTC (18.3967746 seconds, parent zero). Final 904/879 aggregates match; only
HandoffSpec changes, while the other 903 sources, all 57 relocated bodies and all 610 fixtures remain
exact. Cabal/projects, 97 exports and every old fixed hash, five Handoff bundles, separate capability,
response/Relay sections, all 155 existing ordered arrays and 109 path arrays are unchanged. Both full
suites report 26 conditional families, 62 supported rows and 21 refusals, including root encoder `(1,0)`,
POSIX names `(3,0)` and Windows unpaired names `(0,1)`.

The canonical compiled ownership-unit digest passes on 2026-11-02 at 00:02:01 UTC (0.211543
seconds, parent zero, empty stderr), returning current Python-floor digest
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`. Process/remaining metadata
audit passes at 00:02:17.052202 to 00:02:17.510696 UTC (0.423599 seconds, parent zero), retaining
original container StartedAt, init and mounts without surviving test/probe children. Governed docs
accurately separate outer connected DATA behavior from durable coordinator/process/admission claims
and name the actual production/testing Transaction owners.

The sprint closes with one 50-line test addition, no production changes and no remaining work. The
phase stays Active for its other sprints and own terminal gate; closing-status documentation checks follow.


After closing Sprint 13.31 and advancing the table to the already Active Sprint 13.32, all 17 native
DocValidatorSpec cases pass on 2026-11-02 at 00:03:33.808965 to 00:03:40.566458 UTC (6.67 seconds
reported, 6.757533 seconds wall, parent zero). Phase/table harmony, current deferred evidence,
governed links and implementation citations agree.

#### Remaining Work

None.


### Sprint 13.32: Rooted payload and child-config binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (owner-comment alignment only)
**Production budget**: at most 360 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Add an exact rooted binding whose transported payload and child configuration have separately framed signed
identities.

#### Deliverables

- New opaque all-nominal `RootedPayloadBinding scope brokerGeneration` is this sprint's sole named type and
  retains separately framed non-empty `payloadDigest` and `childConfigDigest` claims in canonical signed bytes.
- Config signing and verification require both digests to name the same exact received configuration bytes.
  The config signer refuses recovery-kind offers. The separate package-aware recovery signer and verified
  join are owned by the recovery-package boundary; a rooted recovery value alone establishes only two
  unequal signed claims, while package membership and child-config-field admission require that join.
- The rooted codec owns unsigned canonical bytes; the facade signs/verifies its fixed domain only through the
  package-private admission and a live `RootBroker`, with no generic signer or import cycle.
- Existing immediate-edge `HandoffBinding` remains byte-compatible and truthfully binds its one payload; no
  adapter digest is relabelled as a child-config digest before a rooted package exists.
- Source and compile-fail guards pin the two nominal roles, separately framed digest fields, config equality,
  recovery inequality, canonical round trip, constructor hiding, and every cross-binding refusal.

#### Validation

`HandoffSpec` retains canonical binding round trips, exact config-kind equality, recovery claim distinction
and non-admission, signature/domain coverage, legacy-byte stability and nominal refinement proofs.
Existing direct verifier fixtures use a test oracle; the keyless-relay foundation also supplies a genuine
production-signer positive. This sprint adds direct production signer refusals using the actual
recoverySigningKernel from the existing test-only route, with a matching signer/grant/verified-rooted
positive first. Four otherwise-valid rows assert exact HandoffBindingMismatch details for recovery kind,
empty payload, empty child config and unequal nonempty config bytes.

A fifth runtime backstop uses the existing lower checked-root fixture: one actual principal/session/
allocated epoch supplies independently verified Up and Down roots. Release the protected entry before
opening brokers; a genuine Up offer under the live Down signer receives the exact existing verb-mismatch
detail, after a matching positive. This does not claim ordinary lifecycle admission accepts another verb.
Foreign-generation use remains a nominal static refusal. Distinct provisioned keys under the same valid
binding coordinates do not themselves cause a binding mismatch.

The immediate-edge payload-digest relation is already enforced by the sole opaque mkHandoffOffer producer.
Its constructor/fields are private and roles nominal, so the final signer guard cannot be reached by a
genuine offer that violates that relation. Retain the actual producer rejection, constructor/coercion
proofs and source ordering as evidence of this invariant; no fabricated offer or cast supplies a runtime
row. Existing durable bytes, capability roles and all owned source-freeze subjects remain unchanged.

Every expectBindingRefusal caller supplies a meaningful nonempty expected String fragment, matched against
the actual Text detail with isInfixOf. The oversized whole-wire case pins "is larger than the bounded
authentication field"; the oversized edge-header case pins "contains an oversized field". Preserve each
case's valid earlier subjects so a different decoder refusal cannot satisfy either bound.

The Ed25519 importer census reads disjoint physical src/, internal/ and app/ roots, using lexical imports
and package-relative paths. Its exact three production files are the relocated Activation.hs and Handoff.hs
and src/HostBootstrap/Build.hs. The facade's private import allow-list retains all five declarations:
Internal once, Recovery twice and Rooted twice, including qualified/unqualified multiplicity. Replace only
the former blacklist; retain the independent Protocol reexport-token prohibition and every role,
constructor, producer, strictness, order, type, wire and existing freeze assertion.

The existing Cabal owner comment names the hidden production Transaction copy's actual shared unit and
Main's consumption of it. This is a comment-only alignment of the relocation boundary; component fields,
dependency rows, exports, source roots and compiler visibility remain byte-identical after comments are
excluded. No production Haskell changes are required for the current validation work.

Dated 2026-08-12 evidence: the combined library/test `-Werror -j1` build passed; `HandoffSpec` passed 71/71;
the public compile-fail boundary passed 453/453; `ProjectPlanSpec` passed 68/68; `DocValidatorSpec` passed 2/2;
and canonical `cabal test all --ghc-options=-Werror -j1` passed the 1,917-test suite. Production attribution is
309 significant lines against the 360-line budget: `HostBootstrap.Handoff` adds 140 lines,
`HostBootstrap.Handoff.Rooted` adds 169, and `HostBootstrap.Handoff.Internal` adds zero. Frozen SHA-256 values
are `1fd1a7606e05b04fa15295a0502e8b8b7fed8ec8877694fd79c2657356ea9553` for the facade,
`b2ea6e78f665459a70d35db8a054a9f7481d78bb9fad5dae9b98df6de9cfac1c` for the rooted codec,
`c1f780692658e80d79e7e1033ba520a0c7ac684041fd45de1a5849b262d9acd7` for the hidden admission leaf, and
`e51df058db9dfcd1b867461bdee2f1d5f69c5b2af065bd652daaaa819736ee55` for the Cabal file.

On 2026-11-02, the frozen HandoffSpec change is 178 nonempty/physical test lines, with no production
Haskell change. Two added cases exercise the genuine signer/grant/VerifiedHandoff positive, four exact
reachable kind/byte refusals and the same-epoch checked-root verb backstop with full no-write image.
The checked-root fixture returns a closed IO action only after its protected/authority layers leave the
protected entry. It uses existing private admission and actual producers, with no constructor, cast or
new authority seam. The factory/static invariant retains the unreachable digest relation at its true
construction boundary.

All eighteen refusal-helper calls supply meaningful nonblank source-matching detail fragments. Six
malformed recovery payloads retain their exact bytes/multiplicities while gaining distinct expected
parser details; both real size controls pin their specific bound. The crypto census reads disjoint
physical production roots and pins the three actual paths. The facade whitelist retains all five private
import declarations and the independent neutral-codec/Protocol-reexport prohibitions. Every old role,
type, producer, strictness, order, wire, hash multiplicity, matrix and runtime/frozen section remains.
All 147 prior labels/assertions and 903 unrelated Haskell files are retained. Independent final review
confirms these preserved subjects and genuine lifetimes.

The Cabal correction is exactly one owner-comment replacement; independent review confirms every
noncomment line is baseline-identical, including all component registrations, dependencies, exports,
source roots and visibility. Native test-target compilation refreshes the actual compiler context and
passes at 00:10:28.340054 to 00:10:57.325941 UTC (28.986056 seconds, parent zero, normal warning
policy), with the frozen source hash unchanged before/after. Both direct signer cases pass at
00:12:10.485150 to 00:12:10.637304 UTC (0.07 seconds reported, 0.152159 seconds wall, parent zero).
Actual enumeration selects 999 focused cases; that full run and subsequent static gate remain owed.

The full 999-case focused run passes at 00:12:10.638057 to 00:15:02.039486 UTC (171.31
seconds reported, 171.402446 seconds wall, parent zero), with empty stderr. It covers 149 Handoff,
724 public compiler boundaries, 109 indexed-plan/declaration and 17 documentation cases. Its actual
executable, package-root cwd and selector are retained; artifact-based monitoring recovers completion
without a native rerun when cross-agent process handles are unavailable.

Final synchronization/audit passes at 00:15:18.786927 to 00:15:30.663240 UTC (11.876314 seconds,
parent zero). The 904-file aggregate is
`b2b7c6922861ac1f4200b9c8fa0e0383e380f3e99de4d50341d50793ae35c8db`; the owned 879-file aggregate
is `d08e60906eeb7698c608e447bd9aa88913342f39687a53d9ba20067de7450364`. Independent native
recomputation agrees. Only HandoffSpec changes; other 903 sources, all 57 relocated bodies and 610
fixtures match. The sole Cabal comment change preserves every noncomment byte. All old fixed hashes,
155 ordered requirements, 109 old path arrays, six malformed recovery expressions and both oversized
wire/header inputs retain their subjects. Current docs clarify exact VerifiedHandoff/key verification
and root-side durable consumption as separate operations.

All four Linux commands launch at 00:16:08.974016 UTC after the complete focused pass and verified
sync. Python check_code passes (1.2924035 seconds, parent zero); unfiltered supported test_all passes
376 cases in 5.94 seconds (7.384322 seconds command time, parent zero), with 100% statement/branch
coverage. Demo's own 165 cases pass in 1.43 seconds and its provider wrapper reports no requested live
execution. Standalone core passes all 3,838 tests in 254.99 seconds, Cabal PASS and parent zero
(00:16:08.9740159 to 00:20:52.4752270 UTC; 283.463951 seconds command time). Demo passes its own
165 tests in 1.43 seconds and all 3,838 included core cases in 254.61 seconds, both PASS and parent zero
(00:16:08.9740159 to 00:20:50.5361875 UTC; 281.5245954 seconds command time). Both provider-live
wrappers explicitly report no requested live execution. All four static commands pass; final source,
comment-only metadata, frozen/malformed-byte, current-evidence and process audits follow.

The first consistency audit at 00:21:25.842464 to 00:21:34.715927 UTC stops only at the governed-
document comparison because this plan's dated gate evidence changes after its sync (8.840551 seconds,
parent one); its preceding source/fixture/frozen checks pass. That attempt is retained. With the prose
held stable, current docs are resynced and only this read-only audit repeats; no tests or canonical digest
run again. The strict repeat passes at 00:22:06.2741183 to 00:22:24.6959074 UTC (18.3887118
seconds, parent zero). Both source aggregates match. Only HandoffSpec changes; all 903 other Haskell
files, all 57 relocated bodies and 610 fixtures are exact. Cabal's sole comment change preserves every
noncomment byte; other metadata, 97 exports, all old hashes, five bundles, separate capability, owned
response/Relay slices, 155 existing ordered arrays, 109 old paths and all six malformed/size input
expressions remain unchanged.

The canonical compiled ownership-unit digest passes at 00:21:25 UTC (0.212222 seconds, parent zero,
empty stderr), returning current Python-floor digest
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`. Cleanup/remaining metadata
audit passes at 00:22:16.457918 to 00:22:16.903771 UTC (0.412211 seconds, parent zero), retaining
original container StartedAt, init and mounts without surviving test/probe children. Both actual
conditional summaries report 26 families, 62 supported rows and 21 refusals, including root encoder
`(1,0)`, POSIX names `(3,0)` and Windows unpaired `(0,1)`. Stable governed docs agree with direct signer
scope, factory/nominal invariants, root-side durable consumption and stateless child verification.

The sprint closes with 178 test lines, no production Haskell change, one comment-only metadata alignment
and no remaining work. The phase stays Active for its other sprints and own terminal gate; closing-status
documentation checks follow on the closed tree.


After closing Sprint 13.32 and advancing the table to the already Active Sprint 13.33, all 17 native
DocValidatorSpec cases pass on 2026-11-02 at 00:23:30.126199 to 00:23:35.592211 UTC (5.39 seconds
reported, 5.466046 seconds wall, parent zero). Phase/table harmony, current deferred evidence,
governed links and implementation citations agree.

#### Remaining Work

None.


### Sprint 13.33: Canonical recovery child package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Recovery.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 320 lines across two production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Define the bounded recovery child package and join it to the exact authenticated recovery edge as a neutral
lower layer independent of the receiver and catalog producer. Receiver-carrier adoption and catalog-
derived production remain responsibilities of their consuming scopes; this package boundary does not
claim their process, coordinator or recovery-admission integration is complete.

#### Deliverables

- New opaque `RecoveryChildPackage` is this sprint's sole named type. Its neutral hidden module owns exactly
  the canonical two-frame `{non-empty child config bytes, non-empty adapter bytes}` value; complete canonical
  bytes are at most 8 MiB, and strict decode requires canonical rerender while refusing wrong cardinality,
  empty, oversized, truncated, or trailing input. The public facade exposes the abstract value and renderer,
  not a constructor, parser, or field eliminator.
- Sprint 13.32's config signer and verifier remain additive and exact, with their existing signature and equal
  payload/config requirement. A distinct `signRecoveryChildPackageBindingKernel` consumes the package-private
  recovery-signing capability, a live `RootBroker`, the exact recovery `HandoffOffer`, and one
  `RecoveryChildPackage`; it accepts no separately caller-supplied config bytes or digest pair.
- The facade derives `payloadDigest` from the offer's exact complete package bytes and `childConfigDigest`
  from the package's exact extracted configuration, exact-matches those bytes to the canonical package, and
  refuses a non-recovery edge or any independently chosen payload/config pair before signing.
- `withVerifiedRecoveryChildPackage` requires the already-authenticated `VerifiedHandoff` and treats its
  supplied opaque `RootedPayloadBinding` as untrusted signed data. It rerenders and cryptographically
  reverifies those canonical bytes against that exact handoff and its installed project key before decoding
  the package only from the already-authenticated payload, recomputing both digests, exact-matching the
  immediate edge and complete package, and exposing the two fields inside the successful continuation.
  Package bytes or either signed value alone admit nothing and grant no lifecycle, store, or signing authority.
- The neutral package/signing/join boundary adds no receiver carrier or application producer. Its actual
  current consumer owners are inventoried independently; receiver-carrier and catalog-derived production
  integration belong to their consuming scopes. Cabal metadata and tests do not count as production owners
  or against the two-module budget.

#### Validation

`HandoffSpec` retains the exact two-frame shape, nonempty fields, bounded canonical codec, round trips,
constructor hiding and public cryptographic re-verification of supplied rooted data. Current source has
actual consumer sites: Relay invokes the package signer, Receiver performs the verified join, and
Teardown.Internal produces package data. Exact owner guards retain that inventory rather than asserting
zero call sites. These package tests establish neither those consumers' complete admission/process
integration nor later coordinator semantics.

Each malformed row is otherwise valid through earlier handoff/rooted verification and signs the digest
of the configuration a lax decoder would extract. Missing/empty adapter, trailing and truncated-adapter
rows use the actual child config; the empty-config row uses empty config bytes. The oversized-adapter
header follows a valid first config frame. A valid package passes first, each package-payload digest is
asserted different from its chosen config digest, and each failure retains its exact structural detail
from the strengthened helper. Keep the independent wrong signed-config-digest case unchanged so a
later digest refusal cannot mask the package's intended decoder branch.

A genuine opaque RecoveryChildPackage enters only through the existing public verified-package join.
Inside its forced continuation, the actual private signing capability and live root invoke the package
signer, followed by a real ordinary grant and rooted/package verification positive. Reachable signer
refusals are a normal config-kind offer containing the exact package, a valid recovery-kind offer
containing different canonical package bytes, and an existing same-epoch checked-root verb backstop.
Release the protected entry before broker/signing calls. Retain nominal foreign-generation and hidden-
constructor/static boundaries; no raw package constructor, hidden codec import or new producer is added.

The immediate-edge digest row cannot be independently violated by a genuine offer/package: mkHandoffOffer
already binds its digest to the offer payload, and the earlier signer guard equates that payload to the
rendered package. Preserve those producer/equality/source invariants rather than constructing a runtime
row. Strict fixed-width two-frame decoding has no alternate spelling that reaches the final canonical-
rerender refusal. A complete package above 8 MiB is already rejected by ordinary Handoff framing before
the public package join, so that route does not isolate an equal package-size limit. Retain the actual
source/API bounds and cryptographic/framing evidence without inventing decoder exposure or an authority seam.

Remove only the local derived handoffAttribution binding (measured facade count plus literal six) and its
composite tuple assertion. The current derived tuple is (107, 78, 185); direct facade101 and Recovery78
significant-line pins remain exact. Preserve every role, export, import, producer, opaque/strictness,
order, wire, caller, malformed-input detail and owned raw/Aeson freeze subject; no replacement shared
arithmetic or current whole-source digest supplies completion evidence.

Dated 2026-08-12 evidence: the production library and combined library/test `-Werror -j1` builds passed;
`HandoffSpec` passed 73/73; the public compile-fail boundary passed 455/455; `ProjectPlanSpec` passed 68/68;
`DocValidatorSpec` passed 2/2; an independent security audit passed; and canonical
`cabal test all --ghc-options=-Werror -j1` passed all 1,921 tests. Production attribution is 179 significant
lines against the 320-line budget: `HostBootstrap.Handoff` adds 101 lines and
`HostBootstrap.Handoff.Recovery` adds 78. Frozen SHA-256 values are
`c8d33baf1cf5fc3825f2eb1f983a6af4f91e85a65ee9dd0793e65ff59c535210` for the facade,
`15244530789cfe080ff84c543881158422143758cf9e15885ad47f08839424d1` for the recovery codec, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877` for the Cabal file.

On 2026-11-02, implementation adds 107 nonempty/physical HandoffSpec test lines with no production
change. Malformed rows retain their exact structural details but use the lax-extracted config digest;
the oversized adapter header follows the valid config frame, and explicit distinct-digest assertions
prevent earlier recovery-claim conflation. The valid package and independent wrong-claim controls remain.
Genuine packages come from the public verified join; every returned IO action is forced inside the live
broker. New positive coverage signs a fresh recovery offer, obtains a real grant/VerifiedHandoff, and
checks rooted/package verification. Exact kind/package-byte refusals and the same-epoch Down/Destroy
verb backstop use actual private admission and preserve the full protected image on refusal.

Only the derived binding and two tuple-assertion lines are removed. Direct facade101 and Recovery78
pins remain byte-identical. Exact rollback of the authorized spans restores the baseline; all 149 old
labels, hash multiplicities, 903 unrelated sources and every role/export/importer/producer/opaque/order/
wire/raw/Aeson/runtime control remain. Independent final review confirms package provenance, forced
continuations, checked-root lifetimes, unmasked decoder branches and exact attribution scope.

Native test-target compilation passes at 00:30:07.979853 to 00:30:31.423052 UTC (23.443337
seconds, parent zero, normal warning policy), with source hash unchanged before/after. The modified
package decoder case and both new signer cases pass together at 00:32:07.606506 to 00:32:07.840020
UTC (0.15 seconds reported, 0.233519 seconds wall, parent zero). Actual enumeration selects 1,001 focused cases. All pass at 00:32:07.840523 to 00:35:05.354616
UTC (177.42 seconds reported, 177.515144 seconds wall, parent zero), with empty stderr: 151 Handoff,
724 public compiler boundaries, 109 indexed-plan/declaration and 17 documentation. Current production
library validation remains applicable because all production sources and metadata are unchanged.

The initial external sync audit checks the removal of handoffAttribution too broadly across the entire
test module, where other independent owners legitimately retain that local name. That bookkeeping
assertion is corrected to the exact recovery-package ownership case; source/tests are unchanged and
other attribution bodies are retained. The corrected read-only audit passes at 00:35:31.831842 to
00:35:43.671548 UTC (11.839702 seconds, parent zero), without a native rerun. Both native completion
and final sync pass before the full static gate starts.

The 904-file dated aggregate is
`69c12296205657fd42605cde9ceee64bc1e84789d735c2cba8a6dd0e3bdc39a7`; the owned 879-file aggregate
is `84fa5b7ad07e2b30d0e3ab0ebb86ddb0cade310fa82773b55c4c19d30949b1a2`. Independent native
recomputation agrees. Only HandoffSpec changes, while all 903 other sources, 57 relocated bodies, 610
fixtures, metadata, 97 exports and all fixed subjects remain exact. The direct101/78 pins and unrelated
owners' attribution bodies are preserved; these aggregates do not replace owned freeze expectations.

All four Linux commands launch at approximately 00:36:30.89 UTC. Python check_code passes
(1.3301473 seconds, parent zero); unfiltered supported test_all passes 376 cases in 6.23 seconds
(7.7092525 seconds command time, parent zero), with 100% statement/branch coverage. Demo's own 165
cases pass in 1.57 seconds, with its provider wrapper explicitly not requested. Standalone core passes
all 3,840 cases in 263.70 seconds, Cabal PASS and parent zero (00:36:30.8865194 to 00:41:23.4275717
UTC; 292.5012323 seconds command time). Demo passes its own 165 cases in 1.57 seconds and all 3,840
included core cases in 263.44 seconds, both PASS and parent zero (00:36:30.8849909 to 00:41:22.1273027
UTC; 291.2008976 seconds command time). Both provider-live wrappers explicitly report no requested live
execution. All four static commands pass; no provider, receiver/coordinator process integration or
hardware acceptance is inferred from these package-level observations.

Final strict source audit passes at 00:41:56.5723891 to 00:42:15.9394687 UTC (19.3321217 seconds,
parent zero), with both source aggregates fixed. Only HandoffSpec changes; other 903 sources, all 57
relocated bodies, all 610 fixtures, metadata and 97 exports remain exact. Every old hash, five bundles,
separate capability, response/Relay slices, 155 ordered requirements, 109 old path arrays, prior labels
and detail fragments are retained. Only approved malformed-claim/oversized-adapter repairs and new
signer controls change; retired tuple scope is exact, direct101/78 and other owners' attribution bodies
remain. Current docs stay stable through the audit; the initial external bookkeeping attempt is retained,
and no static gate is rerun for that corrected scope check.

The canonical compiled ownership-unit digest passes at 00:41:56 UTC (0.226154 seconds, parent zero,
empty stderr), returning current Python-floor digest
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`. Process/remaining metadata
audit passes at 00:42:14.143293 to 00:42:14.581005 UTC (0.398983 seconds, parent zero), retaining
original container StartedAt, init and mounts without surviving children. Both actual summaries report
26 conditional families, 62 supported rows and 21 refusals, including root encoder `(1,0)`, POSIX names
`(3,0)` and Windows unpaired names `(0,1)`.

The sprint closes with 107 test lines, no production changes and no remaining work. The phase stays
Active for its other sprints and own terminal gate; closing-status documentation checks follow.


After closing Sprint 13.33 and advancing the table to the already Active Sprint 13.34, all 17 native
DocValidatorSpec cases pass on 2026-11-02 at 00:43:15.122861 to 00:43:21.444855 UTC (6.24 seconds
reported, 6.322032 seconds wall, parent zero). Phase/table harmony, current deferred evidence,
governed links and implementation citations agree.

#### Remaining Work

None.


### Sprint 13.34: Authenticated root scope [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 300 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Define the root-signed primitive that authenticates an exact Production or Harness scope without claiming
Offer, receiver, route, or edge integration.

#### Deliverables

- New opaque nominal `AuthenticatedRootScope scope` is this sprint's sole named type. Its strict canonical
  wire has exactly seven frames: inner codec domain, fixed Word64BE version 1, installed project name, closed
  `production | harness` discriminator, exact run field, installed verification-key digest, and a fixed
  64-byte Ed25519 signature; Production requires an empty run and Harness requires a canonical non-empty run.
- The sole producer consumes a matching `HandoffScope scope` and live `RootBroker scope brokerGeneration verb`,
  derives every field, and accepts no caller-supplied project, kind, run, key digest, signature domain, store,
  generation, verb, Offer, or edge. It signs `frame(hostbootstrap/authenticated-root-scope/v1) <>
  frame(keyDigest) <> frame(canonical unsigned first-six frames)`.
- The verifier consumes an `InstalledProjectIdentity projectId`, independently installed
  `ProjectVerificationKey`, and raw capsule bytes; it enforces total/per-field bounds, exact cardinality and
  canonical rerender, local project/key equality, the closed kind/run relation, and the signature before a
  callback can observe authenticated scope.
- Its closed fold yields `AuthenticatedRootScope (Production projectId)` plus the matching Production
  `HandoffScope`, or introduces fresh `forall runId. AuthenticatedRootScope (Harness projectId runId)` plus the
  matching received Harness `HandoffScope`. Verified run text never mints `HarnessAuthority`, and no
  caller-fixed `runId` parser or result-polymorphic escape exists.
- The capsule proves only project scope and installed-key identity. It has no `brokerGeneration` index and
  grants no Offer, edge, payload, root/Harness-root, command, store, lifecycle, relay, or signing authority;
  Relay/Receiver placement is exclusively Sprint 13.35 and the Phase 19 call site supplies live Harness
  producer evidence.

#### Validation

`HandoffSpec` and public compiler fixtures retain both scope kinds, exact seven-frame encoding,
project/key/kind/run/domain/version validation, cryptographic substitutions, malformed framing/bounds,
expired brokers, nominal constructor/coercion refusal and rank-2 Harness escape. The root-scope wire
matrix uses public verification and independent oracle-signed DATA, without a new private producer seam.

Preserve all 23 existing mutated inputs and compare each complete expected HandoffError through exact
Left equality. Eleven semantic rows pin their own HandoffBindingMismatch details and five cryptographic
rows pin HandoffAuthenticatedRootScopeSignatureInvalid. Establish the matching Harness positive before
its unsigned mutation, alongside the existing Production positive. The malformed run detail is exactly
"the authenticated root scope run is not UTF-8"; a complete signature frame of 63 bytes is exactly
"the authenticated root scope signature has the wrong width".

Framing rows retain the shared decoder's actual categories. Empty or missing frame input is
`HandoffWireTruncated 8 0`; a signature declared at 64 bytes but truncated to 63 is `HandoffWireTruncated 64 63`.
A first-field header declaring maxBound Word64 yields `HandoffWireTooLarge maxBound maxWireBytes`, before
any narrowing. An eighth trailing frame is HandoffBindingMismatch "a lifecycle wire has trailing bytes";
an oversized complete capsule has the authenticated-root-scope wire-bound detail. These are distinct
from the signature-width and UTF-8 semantic checks. Do not coerce every row into BindingMismatch or
invent a runtime row for the unreachable exact-frame-count/canonical-rerender fallback after strict
seven-frame decoding.

Delete the orphan Harness-projection Haddock, which documents no declaration, without introducing a
projection API. Clarify the test module header: ordinary public consumers lack the private signing
admission, while explicit Core-test visibility now exercises the fixed-domain signers; adversarial wire
matrices still use independent oracles. Remove the three literal attribution terms and their derived
sum/self-comparison. Keep the two genuinely measured components explicitly as `scopeSectionAttribution == 193`
and `receivedConstructorAttribution == 4`, preserving their actual sections, every role/import/producer/
strictness/order/wire assertion and all five Handoff bundles, separate capability, response/Relay byte
subjects. No replacement total, shared-file arithmetic or new whole-source hash is introduced.

Dated 2026-08-12 production/API evidence: `HostBootstrap.Handoff` is the sole production owner and adds
205 significant lines against the 300-line budget. Its public facade exposes the abstract
`AuthenticatedRootScope`, `renderAuthenticatedRootScope`, the hidden-capability live-broker
`signAuthenticatedRootScopeKernel` producer, and the closed rank-2
`withAuthenticatedRootScopeFromWire` verifier/fold. `HostBootstrap.Handoff.Protocol`,
`HostBootstrap.Handoff.Relay`, and `HostBootstrap.Handoff.Receiver` have zero production delta for this
sprint, and the existing four-field `Offer` is unchanged and has not adopted the capsule. An independent
security audit passed. The frozen `HostBootstrap.Handoff` SHA-256 is
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`.

Dated 2026-08-12 validation evidence: the combined library/test warning-clean build passed;
`HandoffSpec` passed 76/76; the public compile-fail boundary passed 457/457; `ProjectPlanSpec` passed 68/68;
and `DocValidatorSpec` passed 2/2. Canonical
`cabal test all --ghc-options=-Werror -j1` passed 1,926/1,926 tests in 397.84 seconds.

Dated 2026-11-02 UTC reconciliation: the 23 pre-existing wire inputs now compare their full expected
errors, and the independently signed Harness oracle is accepted before its unsigned run substitution.
The root-scope/source case retains its directly measured 193/4 assertions; three literal attribution
terms, their derived sum and the mixed self-comparison are removed. The module header states the
public/private signer boundary. This is 78 nonempty/78 physical test lines. The sole production edit
removes the 251-byte orphan projection comment (five nonempty/six physical lines, one module); every
other production byte is unchanged. Reciprocal review preserves all 151 prior case labels, all frozen
hash occurrences, the five Handoff bundles, separate capability bundle, raw response/Relay subjects,
610 fixtures, component metadata and 902 unrelated Haskell files.

Native Windows GHC 9.12.4 warning-clean target build passed in 31.661900 seconds, exit 0,
00:49:37.404695 to 00:50:09.066406 UTC. The HandoffSpec cases "authenticated root scopes verify exact Production and generative Harness branches",
"authenticated root scopes refuse every structural and cryptographic substitution", and
"authenticated root scope remains nominal, scope-only, and exactly attributed" passed in 0.81 reported/0.891418 wall seconds, exit 0, 00:50:20.903011 to 00:50:21.794428 UTC.
Both runs held Handoff SHA-256 `7249ed4d7b272d4beb1b9ba4759063486174ec4151f27f0a24cb764b91510820`
and HandoffSpec `ed5b36630f40b853905a3f4861cf7f75f59241e9ba3f2ed60e2d3ffe1657c1d8` exact.
These dated whole-file observations identify the run and do not replace the declaration-owned freezes.
The binary-context and Harness-workflow docs add 18 nonempty/20 physical lines, describing the
seven-frame scope proof, exact refusal categories and verified-run evidence versus live Harness authority.
Focused and full four-leg validation remain owed below.

The initial native 1,001-case focused attempt, 00:50:21.865120 to 00:51:34.591031 UTC,
failed in 72.64 reported/72.726342 wall seconds, exit 1: all 724 compiler-boundary cases could not
resolve Cabal because the direct test process lacked the GHCup PATH entry. The remaining 277 cases
passed. The initial result is retained; only the launch environment is corrected before repeating the
same selection. No source, compiler resolver, matcher, build metadata or assertion is changed for it.

Dated 2026-11-02 UTC final validation: after correcting only the native process PATH, the same
1,001 focused cases passed (151 Handoff, 724 public compiler-boundary, 109 indexed-plan including its
manifest declaration, and 17 documentation cases), 162.50 reported/162.595466 wall seconds, exit 0,
00:51:54.158266 to 00:54:36.752776 UTC, empty stderr and unchanged source hashes. The library-only
Linux preflight also passed, 15.776027 seconds, 00:54:14.162858 to 00:54:29.972448 UTC.

All four linux-cpu host static gate commands passed in the retained init-enabled gate container.
`cabal test all` from `core/` passed all 3,840 cases in 245.82 reported/275.431915 command seconds,
00:55:41.831567 to 01:00:17.303451 UTC. `cabal test all` from `demo/` passed its 165 cases in 1.38 seconds
and the included 3,840 core cases in 245.63 seconds, 283.214549 command seconds,
00:55:41.831567 to 01:00:25.085469 UTC. `poetry run python -m hostbootstrap.check_code` passed in
1.249665 seconds, ending 00:55:43.122453 UTC. The unfiltered supported
`poetry run python -m hostbootstrap.test_all` passed 376 cases in 5.89 reported/7.282682 command seconds,
ending 00:55:49.155713 UTC, with 100% line and branch coverage. Every command exited 0. Both Haskell
legs reported 26 conditional families, 62 supported outcomes and 21 genuine refusals, including root
1/0, POSIX names 3/0 and Windows-unpaired names 0/1. Provider wrappers reported NotRequested; these
static runs claim no live provider or accelerator acceptance.

The independent sync audit passed in 12.163709 seconds, ending 00:53:21.976762 UTC. Its start-time
metadata was overwritten by an external helper variable; the observed duration and completion remain
recorded without inventing a start time. The final source audit passed in 18.295068 seconds,
01:01:08.892472 to 01:01:27.221499 UTC. The 904-file Haskell snapshot remains
`a93fce34cf01fef18996a599f9ce94dcae7359ff7f6b96187caccb442a247ac6`: exactly the authorized comment-only
Handoff edit and HandoffSpec edit, 902 other files unchanged, all 56 other relocated bodies unchanged,
all 57 old source homes absent, all 610 compiler fixtures and component/export metadata exact.
It independently preserves every old case label, all 23 wire input expressions, direct 193/4 measurements,
fixed declaration/capability/raw-response/Relay subjects, 155 ordered arrays and 109 path guards. All 95
synced documents matched. The canonical phase-1 covered-path measurement passed at 01:01:08 UTC in
0.182645 seconds, exit 0 and empty stderr, retaining
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Cleanup and extra metadata checks passed at 01:01:27 UTC in 0.365886 seconds: the original container
StartedAt, init process and mounts remain, with no surviving gate children. These snapshots identify
this run and do not replace the ownership-scoped source freezes.

After closing this sprint and advancing the plan index, native DocValidatorSpec passed all 17 cases in
5.32 reported/5.395620 wall seconds, exit 0, 01:02:30.445740 to 01:02:35.841338 UTC. The scoped
`git diff --check` also passed.

#### Remaining Work

None.


### Sprint 13.35: Scope-first receiver adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 400 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Adopt the Offer's authenticated scope prelude as the first semantic boundary of the in-binary receiver.

#### Deliverables

- A root `BrokerLink` retains the exact live-broker-produced scope capsule; every relayed link retains and
  forwards only those same root-issued canonical bytes, with no capsule signer, project signing key, or route
  for minting a different scope.
- Protocol keeps the existing outer `OfferTag` shape byte-compatible at exactly four bounded opaque fields:
  payload, token, binding, and authentication. It may structurally bound and split all four before capsule
  verification, but performs no binding/payload semantic parse and adds no tag, field, or `Protocol.hs` change.
- `withReceivedHandoffEdge` accepts installed project identity and the independently installed key instead of
  a caller-created `HandoffScope`; it opens only the authentication field's leading capsule, verifies it, and
  enters the closed rank-2 Production/Harness fold before semantically parsing binding or payload.
- Inside that scope continuation the receiver exact-matches the remaining Offer fields, mints the fresh
  challenge locally, verifies the grant with the same installed key, and then preserves the existing closed
  config/recovery classification. Sprint 13.36 solely owns rooted-binding and `RecoveryChildPackage` carrier
  adoption.
- `BrokerLink` and `ReceivedEdge` retain the exact authenticated capsule for descendant/recovery comparison;
  every refusal is sent before return, diagnostics remain on `stderr`, protocol bytes alone use `stdout`, and
  neither scope nor broker-generation evidence escapes its continuation.
- The receiver's refusal announcement goes through `childProtocolSend` using its last admitted live child
  state. Once Receiver or its fixed relayed operation consumes an admitted terminal parent `RefusedTag` or
  exact `AcknowledgedTag`, shared private progress closes monotonically and permits no later child frame,
  including an announcement, a first report after a relayed refusal, or another relayed request.
  A valid parent refusal is never echoed. Unread traffic and wrong-request/invalid acknowledgments retain
  their existing protocol-error semantics; there is no asynchronous reader or new Protocol hook.

#### Validation

`HandoffSpec` covers the unchanged four-field outer shape, strict leading-capsule cardinality, wrong
scope/project/run/key, root-versus-relay capsule identity, replay, semantic binding/payload use before scope
verification, refusal delivery, and rank-2 escape through public cryptographic behavior plus exact
private-source/ownership guards. The authenticated-scope Handoff definition bundle retains its fixed literal
freeze. Protocol import/representation checks preserve the one-way transport boundary: it imports neither
Relay nor Receiver and contains no authenticated-scope representation. This receiver adoption owns no
freeze over the shared decoder, error datatype, or renderer.
The recursive-lifecycle-command phase owns the first real relaunched-child consumer and process fixture.

Closure requires real in-process receiver behavior through Sprint 13.23's private test route, using
bounded pipe pairs and a scripted parent. Genuine installed identity, broker registration, scope/config
signers and grant issuance provide the Offer and the response to the receiver's fresh Challenge. The
positive config continuation reaches Accepted, reports a canonical protocol DATA completion and receives
its exact acknowledgment; this does not claim a lifecycle commit or a Phase 17 process fixture.

An advertised key digest changed after a valid capsule yields exact ReceiverKeyMismatch and the parent
reads RefusedTag code "installed-key-mismatch". A validly signed foreign-project capsule yields the exact
project mismatch/code "unauthenticated". A valid signed Harness capsule is independently accepted by the
scope fold, then pairing it with a Production binding yields the exact scope/binding mismatch/code
"unauthenticated"; the closed receiver fold does not reject a valid Harness scope merely for being Harness.

Preserve strict Protocol decoding. Raw three-field Offer is ReceiverProtocolFailure of
ProtocolWrongFieldCount OfferTag 4 3; a fifth empty Offer field is ProtocolExcessFields OfferTag 4 8.
Neither produces a decoded Offer/request identity, so the child sends no refusal. After a genuine decoded
Offer and Challenge, one-field or three-field Grant bytes produce the actual ProtocolWrongFieldCount or
ProtocolExcessFields in ReceiverProtocolFailure, and the parent reads code "protocol". Do not bypass the
decoder or fabricate ReceiverMalformedMessage values to exercise unreachable defensive arity fallbacks.

The actual read point is part of each terminal case. A parent refuses the emitted Completed report, or
refuses an actual relayed request consumed by Relay; the continuation observes the typed refusal and then
returns Left. Receiver returns ReceiverDeclined without an upper-channel echo. After a relayed refusal,
attempt the first report and a further relayed operation: both must refuse locally without another frame. A matching report/ACK then
continuation Left or real IOException yields ReceiverDeclined or the original exception without a new
frame. Before-report Left/exception controls do announce their real refusal. After each receiver return
or rethrow, close only its output half and require the parent's next read to be ProtocolTruncated 8 0;
this proves silence by EOF rather than a timing window. Bound, await and clean up every worker.

The private shared progress is mechanical state, not a caller-selected observer or policy. Receiver records
its actual admitted sends/receives and preserves the terminal close across callback failure; fixed Relay
operations close it on the real outer refusal result, including the rooted Right(Left(code,detail)) outcome.
A signed rooted Refused carried in Right(Right bytes) remains ordinary response DATA. Provider-dependency
client traffic keeps its existing separate checks rather than being forced through an FSM that does not
admit those tags. The three raw owned Relay transport sections remain unchanged. Sprint 13.40 owns the separate
self-sent Relay refusal progress obligation: when malformed upstream traffic makes Relay itself announce
a refusal, that terminal send must also prevent a later Receiver announcement. This sprint closes only
the admitted consumed-parent terminal paths described above.

For the signature guards, bound each declaration and assert its complete normalized outer tail at the end:
`) -> IO (Either ReceiverError ())` for withReceivedHandoffEdge and `) -> IO (Either Text ())` for the
recovery fold, plus the complete Harness-config callback fragment. Nested callback substrings alone do
not establish either outer result.

Dated 2026-08-12 production/API evidence: the three production owners add 100 significant lines against the
400-line budget: `HostBootstrap.Handoff.Relay` adds 16, `HostBootstrap.Handoff.Receiver` adds 76, and
`HostBootstrap.Handoff.Receiver.Internal` adds 8. This sprint adds no named type. The private
`rootBrokerLink` now consumes the matching `HandoffScope` and mints the one root-issued capsule before
constructing a link; a relayed link copies only the capsule retained by its authenticated parent edge.
`withReceivedHandoffEdge` now consumes the independently installed identity and key and exposes only the
closed Production-config, Production-recovery, Harness-config, and Harness-recovery fixed-unit continuations
after scope verification. `ReceivedEdge` retains the exact typed capsule beside its verified ordinary edge.
This sprint changes neither the Handoff facade, Protocol, the Cabal file, nor the four-field Offer. An
independent security audit passed.

Dated 2026-08-12 validation evidence: the combined library/test `-Werror -j1` build passed;
`HandoffSpec` passed 79/79; the public compile-fail boundary passed 457/457; `ProjectPlanSpec` passed 68/68;
`DocValidatorSpec` passed 2/2; and canonical `cabal test all --ghc-options=-Werror -j1` passed 1,929/1,929
tests in 397.18 seconds. SHA-256 values measured at landing are
`d940f18d34f086447d4c6c5a61b48eae92e22b1bd5f24f6d0bd4c34309d488a5` for Relay,
`bdc76856fcf8a1aeaedf512cf84a44cb2ccb4454b7a68a78e4bf88feab2e1ea9` for Receiver, and
`5f6bb3b569ee73b5a391b21ac08965e66bb5e71a4c4e1450cba57b66b178ae13` for Receiver.Internal, with the
Handoff, Protocol, and Cabal SHA-256 values unchanged from Sprint 13.34 at
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

Dated 2026-11-02 UTC pre-edit ownership measurement: saved baseline
`hostbootstrap-13-35-baseline-btk14qzs` contains all 904 Haskell hashes and the exact three production
owners. The real SourceGuard reader compiled with all 99 actual Core-test arguments unchanged, including
its existing private thinning; only Temp targets/outputs were appended. Compilation passed in 3.407291
seconds, 01:04:48.870479 to 01:04:52.277748 UTC; measurement passed in 0.087736 seconds,
01:04:52.277869 to 01:04:52.365592 UTC, both exit 0 and empty stderr. The ordered Aeson
(name, signature tokens, complete clause lists) bundle for rootedLifecycleRequestPathKernel and
rootedLifecycleResponsePairPathKernel is 1,449 bytes and has fixed saved-baseline digest
`2c1d3856ecd5b29ec4951c4899f2fa59aa31cde5fcabb314413cbf46f0740ea9`.
Their signature token counts are 12/11 and complete clause counts are one each, with 48/88 tokens.
Saved/current arrays and serialized bytes were equal before edits; monitored source/metadata were exact.
This positively owned subject excludes shared ReceivedEdge/progress code. The former whole-Receiver
pin is an unowned unchanged-file complement and has no invented replacement declaration owner.

The first native production build, 01:18:43.758472 to 01:18:45.862141 UTC, failed in 2.103678 seconds,
exit 1, with two GHC-83865 diagnostics at Relay line 652: the lifecycle acknowledgment wrapper omitted
its response callback and therefore wrapped a partial function rather than IO. Source hashes stayed
fixed during the attempt. The result is retained; correcting that application and preserving the caller
callback's masking behavior precedes the repeated build.

Dated 2026-11-02 UTC production reconciliation: the private shared progress records the request and
last admitted live child state, closes monotonically on consumed parent terminal outcomes, and gates
actual refusal emission through childProtocolSend after an atomic claim. All nine fixed relayed
operations, a first terminal report after a relayed refusal, and both provider-client sends reject
closed progress locally. Provider nonce/package/request validation remains separate from the general
child FSM. The rooted outer Right(Left refusal) closes progress; signed inner Refused DATA does not.
Fixed control-operation classification is masked while blocking reads remain interruptible, and the
lifecycle acknowledgment response callback retains its caller's masking state. Existing terminal-sender
MVar cleanup remains intact, with no progress lock held across a blocking read.

The final production change is 231 nonempty/236 physical changed lines across the three declared modules,
within the 400-line limit. Native `cabal build all` from core passed in 10.670622 seconds, exit 0 and empty
stderr, 01:21:42.274412 to 01:21:52.944968 UTC. Source stayed fixed at Receiver SHA-256
`20981223cb5f528221d239febb2e73b180e1fbdb0e264f34a687707aedbe13c6`, Receiver.Internal
`22795b2cf296acdbddafd030f157d766e7fef950e307232d820d96f8daccc8ea`, and Relay
`9659934cedfc514d1db9b84a5b20f06fd1a988b0015baaad7d29fcd98276c96c`. The three owned Relay raw
sections and both Internal path folds remain baseline-identical. No named type, Main public API,
Protocol representation, component edge or Cabal metadata changed. These dated whole-file observations
identify the build rather than introducing shared-file freezes. Runtime and full static validation are
still owed below.

Dated 2026-11-02 UTC test/doc reconciliation: HandoffSpec adds 14 direct cases covering 19 scripted
scenarios, with 449 nonempty/468 physical test lines changed, frozen SHA-256
`37bbee88183b1f19ecd99767cacc34ccbde13fe4380a4cbcdf2f2fe000f32b44`. The group is
"the scripted scope-first receiver". It includes genuine admission and exact report/ACK; wrong advertised
key, foreign project, independently accepted Harness capsule paired with Production binding; raw Offer
and Grant arity errors; before-terminal Left/IOException; consumed report/generic Relay/rooted outer
refusals; first-report and repeated-relay local closure; post-ACK Left/IOException; wrong-request and
invalid-ACK protocol controls; and a signed inner rooted Refused that leaves the exchange open for its
successful report. Every pipe read, worker result and cleanup is bounded, with output-half close and
exact EOF used to detect forbidden extra frames.

All 151 prior case labels remain. The old trailing-offer duplex case has one necessary runtime adoption:
its trailing-three-byte parent error and nested RelayRefusedByPeer stay exact, while its upward proxy
now observes EOF rather than the erroneous extra refusal. Its unmodified positive control still observes
the legitimate child-decline frame. Mechanically affected source fragments retain their ordering and
semantic checks. Only the approved whole-Receiver/Internal pins and shared budget arithmetic are removed,
with the two positively owned Internal functions pinned to the pre-edit 2c1d3856 bundle. All unrelated
source and protocol DATA rows remain exact. Independent reciprocal review passed. Binary-context and
lifecycle-state docs add 17 nonempty/19 physical lines, bounded to the admitted parent terminal behavior;
they claim no process, provider or lifecycle-commit acceptance.

The native test target first built warning-clean in 24.715077 seconds, exit 0,
01:23:55.063457 to 01:24:19.778385 UTC, with all four source hashes fixed. Its first direct run passed
13 of 14 cases but failed the signed-inner-refusal positive: the parent observed RefusedTag before the
expected RootedLifecycleRequestTag. The result is retained, 0.40 reported/0.472159 wall seconds, exit 1,
01:25:20.855481 to 01:25:21.327639 UTC; the focused run was not started. The positive fixture had used
four-byte predecessor text "none", which the real rooted decoder requires to be a 64-byte SHA-256 digest.
Only that DATA field changed to childConfigDigest of fixed descriptive DATA; the same exact request still
feeds the response signature, and every success/response/report/silence assertion is retained. Reciprocal
review passed. The corrected test freeze is 450 nonempty/469 physical lines at
`03e77ba83c4ef25abeda68fdda721f4f6f4e6ce1bd4794696d3b288544f73e0f`; production is unchanged.

The Linux library-only preflight passed in 14.290501 seconds, exit 0,
01:24:58.667475 to 01:25:12.991482 UTC, after syncing only the three frozen production files. All other
901 Haskell files and component metadata in that preflight snapshot remained at the prior closed sprint;
no test or full static gate was claimed by it. Both final assigned docs passed reciprocal review.

The corrected native test target passed in 26.969211 seconds, exit 0 and empty stderr,
01:28:02.242932 to 01:28:29.211981 UTC, with all four final source hashes unchanged. All 14 direct
scripted receiver cases then passed in 0.39 reported/0.462479 wall seconds, exit 0 and empty stderr,
01:29:15.461127 to 01:29:15.923606 UTC. This includes the corrected signed-inner-refusal positive.
The complete focused selection and full four-leg static gate remain owed.

The first complete focused selection passed 1,013 of 1,015 cases but failed two older source guards,
181.85 reported/181.942997 wall seconds, exit 1, 01:29:15.998296 to 01:32:17.940202 UTC. Runtime cases,
all public compiler boundaries, indexed-plan cases and documentation checks passed. The routed-ack
transport guard still expected the pre-wrapper lifecycle lambda; the reverse-descent guard still expected
the partially applied recoverable-open lambda. Both results are retained. Exactly those two literals now
pin the full actual wrapper, authenticated current-frame prefix, argument forwarding, and lifecycle
callback mask/restore behavior; reversing that 4/4-line correction restores the prior test bytes exactly.
No assertion, order requirement, production code or fixed owned subject is removed. Reciprocal review passed.
The final HandoffSpec freeze is 454 nonempty/473 physical lines at
`76ff9133e1ec69c127f781f8279de5080a55aef067e08b0a3190a0b9d6e28153`.

The corrected native target built warning-clean in 27.619429 seconds, exit 0 and empty stderr,
01:34:58.235401 to 01:35:25.854663 UTC. Both previously failing guard cases passed in 3.99 reported/
4.074962 wall seconds, exit 0 and empty stderr, 01:36:48.297098 to 01:36:52.372035 UTC. All four final
source hashes remained fixed. The full focused selection is repeated against that snapshot before any
full four-leg gate launch.

Dated 2026-11-02 UTC final validation: all 1,015 focused cases passed in 163.01 reported/163.092474
wall seconds, exit 0 and empty stderr, 01:36:52.445617 to 01:39:35.537109 UTC. This re-establishes the
14 new cases and both corrected older guards alongside the unchanged public compiler, indexed-plan and
documentation selections. All four final source hashes remained fixed.

All four linux-cpu host static gate commands passed. `cabal test all` from `core/` passed all 3,854 cases
in 244.52 reported/275.900026 command seconds, 01:43:50.521969 to 01:48:26.455296 UTC.
`cabal test all` from `demo/` passed its 165 cases in 1.36 seconds and the included 3,854 core cases in
251.75 seconds, 291.901992 command seconds, 01:43:50.521969 to 01:48:42.457469 UTC.
`poetry run python -m hostbootstrap.check_code` passed in 1.240531 seconds, ending 01:43:51.802501 UTC.
The unfiltered supported `poetry run python -m hostbootstrap.test_all` passed 376 cases in 5.86 reported/
6.927602 command seconds, 01:43:51.033463 to 01:43:57.998736 UTC, with 100% line and branch coverage.
Every command exited 0. Both Haskell legs reported 26 conditional families, 62 supported outcomes and
21 genuine refusals: root 1/0, POSIX names 3/0 and Windows-unpaired names 0/1. Provider-live wrappers
passed as NotRequested; these static gates establish no provider or accelerator acceptance.

The final sync/baseline audit passed in 12.457660 seconds, 01:42:12.257870 to 01:42:24.715531 UTC.
The final source audit passed in 18.771854 seconds, 01:49:23.851902 to 01:49:42.655995 UTC.
Broad 904-file Haskell snapshot SHA-256 is
`31cdacbf0bcc1075f59a9a37a119ab59739401c9bf4187e2867a1e0f06d3bc98`; the owned 879-file snapshot is
`156e1ef63afaaf7fde27d6b519cc5d81c8a86ac4ce873814a52d9209af1a1e11`. Exactly the three declared
production owners and HandoffSpec changed; 900 other Haskell files, 54 other relocated bodies, all 610
compiler fixtures, 97 export pins, component metadata and all 99 package arguments remained fixed.
All 57 old source homes remain absent. All 151 old labels and 14 new labels, 109 path controls, 155
ordered checks (150 exact arrays and five authorized mechanical migrations), five Handoff bundles,
capability, response bytes, three Relay sections and both Internal folds were independently verified.
The two unowned whole-Receiver pins and shared budget arithmetic are replaced only by the pre-edit
positively owned 2c1d3856 bundle, with no other rebase. All 95 held documents matched snapshot
`e25560803dc4b0530f90181d31c620e9ad52f0f584ebc85f7dbc9b82809f5830`.

Canonical phase-1 covered-path measurement passed at 01:49:23 UTC in 0.179112 seconds, exit 0 and empty
stderr, retaining `0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Cleanup and extra metadata checks passed at 01:50:12 UTC in 0.357029 seconds: original container StartedAt,
init and mounts retained, with no surviving gate children. These dated snapshots identify the audited
run and do not replace declaration-owned freezes. The earlier compiler, positive-fixture and source-guard
failures remain recorded separately above.

After closing Sprint 13.35 and advancing the plan index, native DocValidatorSpec passed all 17 cases in
5.53 reported/5.601506 wall seconds, exit 0, 01:51:54.059844 to 01:51:59.661316 UTC. The scoped
`git diff --check` also passed.

#### Remaining Work

None.


### Sprint 13.36: Rooted carrier and recovery-package receiver adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`, `documents/engineering/testing.md`

#### Objective

Adopt one lower post-open rooted-proof carrier so config and recovery branches expose bytes only after their
exact signed binding and package-aware join, without constructing a real production recovery package.
The current change owns Handoff, Receiver and Receiver.Internal; Relay remains unchanged carrier context.

#### Deliverables

- The unchanged four-field Offer's nested authentication value has strict closed shapes: config carries exact
  capsule/key/rooted fields; recovery carries exact capsule/key/rooted/projection/grant fields. Relay and
  Receiver enforce a 7 MiB embedded Offer-payload sub-ceiling. That sub-ceiling is not a whole-frame guarantee:
  Protocol's authoritative 8 MiB total-body check may still refuse after the other Offer fields and framing
  overhead are included. Wrong size, cardinality, trailing bytes, kind, signer, edge, or cross-paired proof
  refuses before branch exposure.
- The one private carrier requests rooted signing only after an exact `HandoffOffer` exists. Its root route uses
  the already-installed package-private signing kernel and live broker; a nested link relays canonical signing
  request/response bytes only and receives no signing capability. Config admission preserves identical
  payload/config bytes, while recovery uses the package-aware verified join so neither rooted signed data nor
  package bytes alone exposes either package field.
- `ReceivedRecoveryDescent` retains the exact `ReceivedEdge`, verified `RootedPayloadBinding`, opaque
  `RecoveryChildPackage`, closed verb, typed `RecoveryProjectionBinding`, typed `RecoveryWireGrant`, and
  `VerifiedRecoveryWire`. Its existing six-argument eliminator derives the package bytes, authenticated adapter,
  rendered projection, and grant signature from those retained values; it accepts no independently supplied raw
  adapter, projection, or grant. `RecoveryProjectionBindingInput` exports read-only accessor functions and no
  record field labels, so a record update can neither replace a coordinate's text under its existing index nor
  retag the value with caller-chosen `planDigest`, `parentFrame`, or `childFrame` indices.
- This lower sprint produces no real recovery package and composes none on the reverse route:
  `RecoveryAdmission` authenticates only the extracted adapter, while Sprint 17.30's catalog-backed
  `EdgeAdmission` owns the complete package configuration
  and payload digest before the exact Offer is routed to the installed root signer.
- Work remains one private offer/receive carrier adoption across the three named production owners, adds no
  named type or application producer, and grants no signer, store, journal, cursor, command, or lifecycle
  authority. Sprint 17.30 remains the sole real catalog-derived package producer.

#### Validation

`HandoffSpec` covers lower config and package-aware recovery success; exact nested cardinalities; the
independent authoritative Protocol total-body refusal; wrong capsule,
key, rooted binding, projection, grant, payload kind, package, config field, adapter, signer, edge, and
cross-pairing; strict package failures; relayed exact-byte signing; severed-route refusal; and no callback
before every join. Exact source/ownership guards
pin three production owners, one carrier adoption, no new type or public signer, `RecoveryAdmission`'s
adapter-only responsibility, and zero catalog/application producers. The carrier guard retains its owned
Handoff package/signing/verification definition-bundle hash, payload-before-semantics ordering, four-field
Offer API, and independent whole-body bound. It owns no freeze over unrelated Protocol decoder/error
implementation. Phase 17 owns the first real package-producing process fixture.

The sub-ceiling, recovery-phase and cross-paired-proof receiver rows below remain owed at this frontier.
Closure uses Sprint 13.35's genuine scripted-parent harness: an
Offer whose embedded payload is one byte over 7 MiB refused with `ReceiverWrongEdge "the embedded Offer payload
exceeds its strict sub-ceiling"` before any branch is exposed; a recovery Offer whose binding phase is not
`teardown` refused with the "a recovery adapter must authorize teardown" detail; and a recovery Offer with a
cross-paired rooted proof refused before the recovery continuation runs. It also requires compile-fail
fixtures that record-update each `RecoveryProjectionBindingInput` field and retag its indices by a
type-changing update, all refused.

The 7 MiB sub-ceiling is pinned only as source text (the constant's spelling and the
`requireOfferPayloadBound payload` call order), so `requireOfferPayloadBound _ = pure ()` passes. Closure
also requires: an Offer whose embedded payload is exactly `maxEmbeddedOfferPayloadBytes` admitted by the
receiver; `offerHandoffEdge` (through Sprint 13.23's test-only route to `Handoff.Relay`) refusing a payload of
`maxEmbeddedOfferPayloadBytes + 1` bytes with its `RelayError` before any edge is opened; a recovery binding
with an unsupported verb and phase `teardown` refused with a detail naming the verb, not the phase. In
"rooted carrier adoption is bounded, acyclic, exactly attributed, and freezes shared surfaces", the receive
bound's message names the order the receiver has (after the scope capsule is verified with the installed key,
before installed-key digest, binding, or branch interpretation), and the case asserts no line budget: its
three line counts are literals compared with themselves, and `7 * 1024 * 1024 < 8 * 1024 * 1024` is a
constant.

The receiver over-limit row supplies a genuinely authenticated scope capsule and first proves its raw
Offer is below Protocol's separate 8,388,608-byte body bound. It must refuse immediately before Challenge,
Accepted or branch entry. Exactly 7,340,032 bytes admits through genuine registration, rooted proof,
fresh Challenge, grant and report/ACK; 7,340,033 bytes triggers the receiver sub-ceiling. The real
rootBrokerLink/offerHandoffEdge over-limit case also proves admission count zero and a complete unchanged
protected-store image. All large sends and worker lifetimes use the whole-action bound.

A matching genuine Down recovery success precedes the phase/cross-paired-proof negatives. Observe the
opaque recovery callback and Relay.withRecoveryBrokerLink/report/ACK without importing Receiver.Internal
or exposing its private eliminator. The cross-pair keeps genuine A package/offer/grant and substitutes a
genuine B rooted proof; it must return the exact rooted-edge mismatch with recovery callback count zero.

Unsupported wire verb is a separate hostile-DATA case. The real broker derives and checks a closed
ProjectVerb and cannot grant it. Keep genuine Down scope/key/token/package/projection/adapter evidence,
change only binding field 10 and the dependent independent ordinary-grant signature over the actual
observed Challenge. The same known-key oracle must first admit the unchanged Down transcript through
recovery/report/ACK. Production grant material is exactly framed domain, framed eight-byte version 1,
framed installed-key digest, framed canonical binding, once-framed raw token and framed actual challenge;
payload is bound through the binding digest. Receiver classifies verb/phase before interpreting the later
recovery evidence, so the hostile transcript proves the verb refusal and makes no claim that a broker
issued it or that its later recovery join would succeed.

The field privacy proof uses the official Main-only compiler context, not the Core-test thinning. Before
editing, both planned opaque-parameter subjects must compile: field replacement for each of the three
coordinates, and independent value-preserving type-changing updates for all three nominal indices.
After private labels/plain getters, the same bytes must fail with their measured field-update diagnostic,
while a getter tuple control remains valid. Keep existing forge/coerce/escape bytes and constructor-proof
intent; measure actual constructor diagnostics before adjusting any existing expectation. All five fixed
Handoff declaration bundles, the 13-reader/26-line subject, signing capability, path-fold bundle, response
bytes and three Relay sections exclude this producer change and remain unchanged. No new freeze or
shared-file arithmetic is needed.

Dated 2026-11-02 UTC pre-edit compiler evidence: saved baseline
`hostbootstrap-13-36-baseline-p1shu_fo` contains 25 source/doc texts and 904 Haskell hashes. Current
`cabal path` and the unique Main registration were re-resolved through the existing public-fixture route.
Only base, bytestring, process, text and the registered Main unit were exposed with explicit global,
store and local package databases; no private unit, test thinning or home-source path was present.
UpdateRecoveryProjectionInputField compiled all three field replacements, exit 0 in 0.192280 seconds,
01:54:00.396258 to 01:54:00.588538 UTC. RetagRecoveryProjectionInput compiled all three independent
nominal retags, exit 0 in 0.190129 seconds, 01:54:00.589209 to 01:54:00.779331 UTC. The getter tuple
control passed in 0.188518 seconds, 01:54:00.779832 to 01:54:00.968342 UTC. All three had empty stderr.
Their source SHA-256 values are respectively
`733388ded236cf34ca9e104e251438c81efd22561967c2829e1cf9ac092ba233`,
`b94862c47181b49ef12ba2bc481aeb9780801b849cdc22ca2359036431d7a602`, and
`81bbbdb30c742f7fd9437d81b8d9c9d9ec0af93a516bac944058869e6ed434a9`.
Production source, Cabal registration and plan metadata remained exact during these witnesses.

Dated 2026-08-12 production/API evidence: the three production owners add 145 significant lines against the
400-line budget: `HostBootstrap.Handoff.Relay` adds 119, `HostBootstrap.Handoff.Receiver` adds 9, and
`HostBootstrap.Handoff.Receiver.Internal` adds 17. The sprint adds no named type or real package producer.
An independent security audit passed.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test `-Werror -j1` build passed;
`HandoffSpec` passed 82/82 in 22.71 seconds; the public compile-fail boundary passed 457/457 in 107.53
seconds; `ProjectPlanSpec` passed 68/68 in 12.73 seconds; and `DocValidatorSpec` passed 2/2 in 0.25 seconds.
Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all 1,932 tests in
402.38 seconds; the suite passed.
SHA-256 values measured at landing are
`bf577a55a33c76e4636a9b80019adc31988831990d0261f1bbb3bf5036ba2457` for Relay,
`47d1b8826240bc15bf85561292af77fb8f9a615a417db6b44ceba1531c7316fc` for Receiver, and
`b3720a38158b963f2b7aa63a96b20658ffde57cda42efda8ec6df39d8d48cad8` for Receiver.Internal, with the
Handoff, Protocol, Rooted, Recovery, Handoff.Internal, and Cabal SHA-256 values unchanged by this sprint at
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`,
`b2ea6e78f665459a70d35db8a054a9f7481d78bb9fad5dae9b98df6de9cfac1c`,
`15244530789cfe080ff84c543881158422143758cf9e15885ad47f08839424d1`,
`c1f780692658e80d79e7e1033ba520a0c7ac684041fd45de1a5849b262d9acd7`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

Dated 2026-11-02 UTC reconciliation: the final production delta is 46 nonempty/50 physical lines across
Handoff, Receiver and Receiver.Internal. Handoff uses private input labels and same-name plain getters;
its explicit Show instance preserves the prior public label names/order, precedence and constructor-match
WHNF strictness. Receiver names an unsupported teardown verb while retaining the wrong-phase detail.
The private eliminator Haddock now states its six actual arguments and four derived byte views. Relay,
Protocol, component metadata and every independent frozen subject are unchanged. The final production
SHA-256 observations are Handoff `8bd0a27b528108c08939c237903b5cc03854c7019e680942757e6095a89efa38`,
Receiver `80a967814e317683e96b031777627a0b70f32b92c30b8a039084799b3f02584b` and Receiver.Internal
`6ae3159bb9554fb247868c197baecf5bcb9ef8e1ed23fd5e12679722de2e58b7`.

The first native production build passed in 25.566644 seconds, exit 0, 02:00:13.321583 to
02:00:38.888071 UTC. A subsequent one-line Show strictness preservation was then rebuilt warning-clean
in 19.316182 seconds, exit 0 and empty stderr, 02:02:25.454176 to 02:02:44.770241 UTC. All monitored
source/metadata stayed fixed within each run. The prior compiled public Show witness at precedences
0, 10 and 11 compiled/ran in 1.534744/0.206252 seconds, 01:58:57.497471 to 01:58:59.238497 UTC;
it explicitly observed the pre-edit compiled package while source work was unbuilt. Recompiling the same
public witness after the final build took 1.545453 seconds and its run took 0.257582 seconds, ending
02:03:46.795284 UTC; both exited 0 with empty stderr and rendered exactly the same three strings.

After privacy, the byte-identical public getter tuple still compiled, exit 0/0.164090 seconds,
02:03:44.344693 to 02:03:44.508784 UTC. The original update/retag subjects failed in 0.178072/0.146661
seconds, 02:03:44.509807 to 02:03:44.834982 UTC, with measured GHC-22385 "Not in scope: record field
'requestedRecoveryPlanDigest'". The unchanged ForgeRecoveryProjectionInput fixture still failed for its
original GHC-01928 illegal term-level constructor reason in 0.156354 seconds, ending 02:03:44.991812 UTC.
No constructor-proof expectation or resolver/matcher was weakened.

GHC reports only the first bad field in each combined subject. Four additional fixtures isolate parent
and child updates/retags, so the permanent suite tests all six paths independently. Their function bodies
are unchanged extractions from the pre-edit successfully compiled subjects. All four were measured with
the same official Main-only arguments, exit 1, 02:08:18.747625 to 02:08:19.340780 UTC, taking
0.145762, 0.144701, 0.143766 and 0.157449 seconds. Each GHC-22385 diagnostic names its own exact parent
or child field. The two original subjects and four isolated subjects are registered once each with their
complete measured record-field phrases; a Main-only getter control is also permanent. All 610 original
fixture bytes and every old registration are unchanged, giving 616 fixtures. Compiler-lane reciprocal
review passed; no private unit, home-source path or Core-test exposure entered the public context.

HandoffSpec adds nine cases/ten scenarios in "the bounded rooted recovery carrier", 287 nonempty/296
physical test lines, SHA-256 `8b6d5eae97a671dee335bbd9c844cb35687e44b1ea472846920154131af5935a`.
Its old 165 labels, fixed hash multiplicities, path controls, scripted receiver cases and Protocol matrix
remain intact; reversing only the authorized additions/carrier-literal removals restores the baseline.
All real pipe dialogs, large writes and worker cleanup are bounded. Both production/test and compiler
lanes passed reciprocal review. The two assigned docs add 24 nonempty/28 physical lines and distinguish
primitive/genuine recovery controls from the independent hostile-wire oracle and later application work.

The final native test target built warning-clean in 48.639341 seconds, exit 0,
02:10:19.427750 to 02:11:08.066793 UTC. All 16 direct runtime/compiler checks passed in 1.70 reported/
1.781985 wall seconds, exit 0 and empty stderr, 02:12:36.700339 to 02:12:38.482320 UTC. The production-only
Linux preflight passed in 33.316054 seconds, exit 0, 02:11:19.170177 to 02:11:52.519724 UTC, after a
0.880320-second three-file sync retaining the other 901 prior snapshot files. That preflight ran no tests.
The complete focused selection and full four-leg gate remain owed.

Dated 2026-11-02 UTC first full-gate attempt: the original 1,031 native focused cases passed in
168.68 reported/168.772680 wall seconds, exit 0 and empty stderr, 02:12:38.557306 to 02:15:27.328958 UTC.
The baseline audit subsequently passed in 12.679760 seconds, 02:18:47.389257 to 02:19:00.069020 UTC.
Two earlier external audit-helper assumptions were corrected: one approved eliminator assertion label
lay just outside its reconstruction region, and a direct-registration census omitted five existing
bounded tuple registrations. Both exception captures/exit 1 results remain retained. Those helpers
printed timing only on success, so their full UTC/durations are unavailable; tool yields are not
substituted as command durations. No source or tests changed for either correction.

All four commands launched at 02:19:16 UTC. Python checks passed in 4.065693 seconds; the unfiltered
Python suite passed 376/5.89 reported/10.121805 command seconds with 100% line and branch coverage.
The demo's own 165 cases passed in 1.43 seconds. Both core suites then stalled without final summaries.
These are partial results, not a completed gate. Live process checks found only main and ticker OS
threads, with both main threads in anon_pipe_write. A host-namespace syscall read identified write to
fd 9 of 0x7005c8 bytes, exactly 7,340,032 payload bytes plus 1,480 bytes of genuine Offer framing and
authentication. The peer reader and five-second timeout could not run under the non-threaded RTS.
No compiler/probe child or terminal-sender cleanup cycle accounted for the wait.

The verified hung process trees were stopped with TERM at 02:34:14.891 UTC, remaining wrappers/parents
at 02:34:18.908, and bounded KILL only for the still-blocked test processes at 02:34:21.922. Core parent
returned 1 at 02:34:20.933856 after 904.731448 command seconds; demo parent returned 1 at
02:34:21.950005 after 905.741544 seconds. Both runs are cancelled/unfinished diagnosed hangs, with no
final core pass count or assertion-failure claim. A 0.339634-second cleanup check at 02:35:03.623052 to
02:35:03.962679 UTC confirmed no remaining children and retained container/init/mounts.

The narrow harness correction adds only `ghc-options: -threaded` and its explanation to the core-test
stanza. Production Haskell, the real Protocol sender, exact 7 MiB payload and every timeout/assertion
remain unchanged. Cabal source SHA-256 is now
`d7415b69aea89fa59f46ed895f67eb82b1b7a9ac67cc73b916b3f19564d39260`; source module/dependency graphs,
exports, private four-module thinning and all prior compiler arguments are preserved. Actual native
arguments are 99 to 100 and Linux arguments 101 to 102 because of its existing Unix edge; each adds
only -threaded. The Linux correction build passed in 31.589419 seconds, 02:36:54.999570 to
02:37:26.626005 UTC. Its linked binary reported rts_thr; all nine carrier cases then passed in
0.59 reported/0.888412 wall seconds, exit 0 and empty stderr, 02:38:53.817557 to 02:38:54.705968 UTC.

The first native rebuild passed in 32.268795 seconds, 02:36:31.411434 to 02:37:03.680032 UTC, and
recorded the new flag, but the separate runtime verification found its cached old rts_v executable.
That verification failure is retained. Removing only the exact cached executable did not invalidate
Cabal's component build monitor, and the next plain build left the executable absent; that verification
exception is also retained without invented timing. Discarding only the verified component opt/cache/build
monitor, preserving configuration, registration and object files, made plain Cabal relink in 6.502482
seconds, exit 0, 02:43:20.985864 to 02:43:27.488306 UTC. The actual native executable then reported
rts_thr and retained all 99 prior arguments plus the one declared flag. No global clean, force-recomp,
source change or alternate compiler command was used.

The native threaded direct selection passed all 16 cases again in 1.72 reported/1.819266 wall seconds,
exit 0 and empty stderr, 02:45:48.877532 to 02:45:50.696788 UTC. The canonical testing doc adds four
nonempty/five physical lines explaining the scheduler requirement. The focused selection and all four
static gate commands must pass against this corrected snapshot before closure; initial partial passes
do not close either cancelled Haskell leg.

Dated 2026-11-02 UTC corrected closure evidence: the threaded native focused selection passed all
1,031 cases in 173.37 reported/173.522990 wall seconds, exit 0 and empty stderr,
02:45:50.774755 to 02:48:44.296688 UTC, with source and corrected Cabal hashes fixed. The final
corrected sync audit passed in 12.743513 body seconds, 02:52:39.218886 to 02:52:51.962398 UTC.
The demo's normal test-target rebuild passed in 17.257835 seconds, 02:52:38.503549 to
02:52:55.795256 UTC; its actual binary reported rts_thr at 02:53:45 UTC. No demo cache invalidation
was needed. Its 102 arguments match the Linux core component after build-path normalization.

All four fresh static gate commands passed against the corrected snapshot. `cabal test all` from core
passed all 3,870 cases in 270.59 reported/278.740057 command seconds, exit 0,
02:53:52.599790 to 02:58:31.375563 UTC. `cabal test all` from demo passed its 165 cases in 1.58 seconds
and the included 3,870 core cases in 273.16 seconds, exit 0/277.490603 command seconds,
02:53:52.610889 to 02:58:30.134718 UTC. `poetry run python -m hostbootstrap.check_code` passed in
0.819353 seconds, 02:53:52.622439 to 02:53:53.478810 UTC. The unfiltered supported
`poetry run python -m hostbootstrap.test_all` passed 376 cases in 5.93 reported/6.913861 command seconds,
02:53:52.635184 to 02:53:59.587038 UTC, exit 0 and 100% line/branch coverage. Both full Haskell legs
reported 26 conditional families, 62 supported outcomes and 21 genuine refusals: root 1/0, POSIX files
3/0 and Windows-unpaired names 0/1. Provider-live wrappers passed as NotRequested; no live provider or
accelerator acceptance is claimed. These completed runs, not the earlier cancelled ones, close the sprint.

The final source/doc audit passed in 9.903683 body/14.783525 outer seconds,
02:59:04.620976 to 02:59:14.524659 UTC. All 910 Haskell files remain at
`d91fbeab19fbb16857a29a5e36da82ad4138336c8cb63489c1d014c9b9aa6b53`; the owned 885 remain at
`fe3cf36ee4099ddccd2ba5033b63e58e3840d988c9e431a0b66478b47c5cc6d6`. Five original Haskell files
changed and six fixtures were added; 899 original files, all 610 original fixtures, 54 other relocated
bodies, all 155 ordered arrays, 109 paths, five Handoff bundles, capability/path/response/Relay byte
subjects, reader and export controls remain exact. All 57 old source homes remain absent; 616 fixtures
are uniquely registered. The only Cabal source delta is the two-line core-test threading explanation/flag;
module, dependency, export and private-thinning rows are preserved. Native and Linux argument counts are
100/102 respectively, each retaining every prior host-specific argument plus the declared flag.
All 95 held docs matched `6f611461c02fbf2f583cfbf6692320c0eb32eeef24c48af6136237342d882a5b`.
The initial Linux sync helper's native99-count assumption stopped before copying; measuring its actual
101 arguments corrected that external assumption without removing an argument or altering source.

Canonical phase-1 covered-path measurement passed at 02:59:04 to 02:59:05 UTC in 0.209578 seconds,
exit 0, retaining `0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Cleanup/extra-metadata checks passed in 0.341334 seconds, 02:59:26.519975 to 02:59:26.861308 UTC,
with no test/probe children and original container StartedAt, init and mounts retained. These dated
observations identify the successful run; no shared-source freeze or guard expectation was rebased.

After closing Sprint 13.36 and advancing the index, native DocValidatorSpec passed all 17 cases in
6.37 reported/6.446731 wall seconds, exit 0, 03:02:17.608301 to 03:02:24.054999 UTC. Scoped
`git diff --check` also passed.

#### Remaining Work

None.


### Sprint 13.37: Closed rooted lifecycle request [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 340 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Define the complete bounded request vocabulary for the later storeless frame-executor exchange with the root
coordinator. The remaining implementation is public decoder coverage and guard reconciliation in
HandoffSpec, with zero production delta.

#### Deliverables

- The existing hidden `HostBootstrap.Handoff.Rooted` module adds one non-indexed opaque
  `RootedLifecycleRequest` with exactly the closed variants `OpenFrame`, `NextNode`, `SettleNode`,
  `DescendResult`, `CloseFrame`, and `ReceiptConfirm`; `Rooted.hs` is the sole production owner and Protocol
  has zero byte/line delta.
- `OpenFrame` has exactly four top-level length-delimited frames: domain
  `hostbootstrap/rooted-lifecycle-request`, canonical Word64BE version 1, discriminator `open-frame`, and an
  exact 32-byte nonce. It carries no requester path, session, stage, ordinal, predecessor-response digest,
  observation, descent result, or caller-selected verb.
- `NextNode`, `CloseFrame`, and `ReceiptConfirm` have exactly nine top-level frames: the same domain/version,
  exact discriminator and path, non-empty session and stage, nonzero Word64BE ordinal, exact 32-byte nonce,
  and exactly 64 lowercase hexadecimal bytes for the digest of the exact complete prior canonical signed
  response field. Their discriminators are `next-node`, `close-frame`, and `receipt-confirm`; `SettleNode`
  and `DescendResult` use `settle-node` and `descend-result` and append one non-empty opaque observation or
  descent-result wire as a tenth frame.
- A post-open requester path is one to 256 nested non-empty UTF-8 component frames, each at most 4,096 bytes,
  in root-nearest-to-leaf Relay order: the first component is the exact child admitted by the serving root or
  hop and the last is the originating requester/current parent. Session and stage are root-issued opaque UTF-8
  tokens echoed byte-exact and each at most 4,096 bytes; a complete request is at most 7 MiB and an opaque
  observation/result field at most 6 MiB.
- Strict decode requires exact canonical rerendering and no trailing bytes, and rejects unknown variants,
  cardinality, encoding, emptiness, zero ordinal, digest, nonce, path, and size violations. This sprint
  changes neither the singleton `RootedLifecycleRequestTag` field nor Protocol's independent 8 MiB
  total-body bound. The opaque tenth frame gains no semantic claim here: Sprint 13.40 uses the sealed
  external requester envelope as `OpenFrame` ancestry and structurally checks intermediate suffixes and root
  equality. Phase 17 resolves that path against authenticated scope/runtime/catalog/session before mutation
  and owns retained-session equality, typed-body canonicality/admission, session/stage meaning, freshness,
  ordinal derivation, predecessor correspondence, ordering, and replay.

#### Validation

Three `HandoffSpec` source-guard cases cover all six exact discriminators, the exact 4/9/10 top-level
cardinalities, nested root-nearest-to-leaf requester-path order, every scalar and total bound, canonical
rerender/no trailing bytes, and malformed/unknown/cross-variant refusal branches. They inspect the exact hidden
source without importing or executing the codec. Source and import guards pin the single hidden owner,
owned Rooted/Handoff section and definition-bundle hashes, the consumed singleton Protocol tag/field API,
non-indexed type, closed fold, and absence of authority, protected-store, cryptography,
command, generic storage operations, a testing companion, or semantic/process/durable importers. Sprint 13.40
adds the sole neutral Receiver-internal path fold for Relay transport.

The public withVerifiedRootedLifecycleResponse decodes exactRequest before response decoding, pairing,
signature/report work or callback. Add one table of 19 malformed exact requests through that actual public
boundary, preserving the existing wrong-domain case. Canonical NextNode/Prepared and SettleNode/Settled
controls first pass using the same genuine installed key and existing independent response DATA oracle.
For each negative, sign over its exact malformed request bytes and a structurally valid response whose
request-digest field is childConfigDigest of those bytes. An invalid request has no semantically matching
opaque response; the case proves request-before-response rejection, not a successful malformed pairing.
Compare the complete Left HandoffBindingMismatch detail and callback count zero. If Right contains IO,
force that actual callback before failing so a zero counter cannot be a laziness artifact.

The exact details below all carry the public wrapper prefix "rooted lifecycle response ": version 2,
"has the wrong lifecycle request version"; unknown discriminator, "has an unknown rooted lifecycle request
variant"; eight- and ten-field NextNode, "post-open rooted lifecycle request has the wrong field count";
empty path, "has an empty requester path"; 257 components, "has more than 256 requester path components";
4,097-byte component, "requester path component is oversized"; empty session/stage, "has an empty session"
and "has an empty stage"; invalid-UTF-8 session/stage, "has a session that is not valid UTF-8" and "has a
stage that is not valid UTF-8"; 4,097-byte session, "has an oversized session"; 63-byte predecessor,
"has a predecessor response digest whose width is not 64 bytes"; uppercase digest, "predecessor response
digest is not canonical lowercase SHA-256"; zero ordinal, "has a zero ordinal"; seven-byte ordinal,
"has a noncanonical ordinal width"; 31-byte nonce, "has a nonce whose width is not 32 bytes"; empty
SettleNode observation, "has an empty lifecycle request body"; and one raw trailing byte after a valid
nine-frame NextNode, "rooted lifecycle request field is truncated before its frame header".

A complete extra frame would instead repeat the wrong-count refusal; do not invent a generic trailing
category. Strict fixed framing, exact Word64 width, valid UTF-8 and lowercase digest decoding leave no
independent alternate encoding to reach the final rerender inequality. The constructor's path-cardinality
backstop is likewise masked by actual empty/>256 decoder refusals. Retain those source backstops without
forging opaque malformed state, exposing the hidden codec or adding a runtime seam.

Delete only the FIRST request-ownership guard's literal terms frozenRootedPayloadLines (169),
frozenRootedRequestLines (504), frozenRootedRequestDigest (45ca89f2...), rootedRequestDelta and their three
self/budget assertions. The payload count is a dead input once that arithmetic is removed. Preserve the
separate Done Sprint 13.38 response guard's same-named historical variables, genuine 757/253 measurements
and 55cede hash, the fixed 81d964 request-decoder bundle, all import/type/role/count/order/Protocol
singleton controls, and every other owned subject. The original 335/340 attribution below stays dated
landing evidence; no replacement sum, line offset or current-source rehash is introduced.

Dated 2026-08-12 production/API evidence: at landing `HostBootstrap.Handoff.Rooted`, the sole production
owner, measured 504 significant lines. The request adds 335 lines to the 169-line rooted-binding owner, within the
340-line budget. The sprint adds no other production owner or runtime seam, and an independent security/source
audit passed. Its SHA-256 measured at landing is
`45ca89f24b43cbf4b02e2d82186e8c33db5e2aaedb6978d2111e039ae6933281`, with the Handoff, Protocol, and Cabal
SHA-256 values unchanged by this sprint at
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test `-Werror -j1` build passed
in 41.85 seconds; `HandoffSpec` passed 85/85 in 23.54 seconds (42.67 seconds wall); the public compile-fail
boundary passed 457/457 in 107.68 seconds (107.75 seconds wall); and `ProjectPlanSpec` passed 68/68 in 12.55
seconds (12.63 seconds wall).
Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all 1,935 tests in
404.84 seconds; the suite reported PASS.

Dated 2026-11-02 UTC reconciliation: HandoffSpec changes 97 nonempty/97 physical test lines at
SHA-256 `e1e70cd4b1f9dd60bd4d73e339a08c455e2528b2038a4c1c0ec0a9cf727393f2`, with zero production,
component, compiler-fixture or representation delta. The case "the public response verifier refuses
nineteen exact malformed requests before its callback" runs both valid pairs first, each with actual
callback count one, then independently signs a structurally valid response over every malformed request
and its actual digest. All 19 complete prefixed decoder errors and zero callback counts are compared;
unexpected Right executes its IO callback before failing. This is public request-first verification
coverage and creates no hidden parser route or semantic pairing for invalid requests.

Only the first request-ownership guard's dead literal 169/504/digest/delta terms and three self/budget
comparisons are removed. The entire separate Done-13.38 response-pairing guard remains byte-identical,
including its same-named historical terms, real 757/253 measurements and 55cede digest. Explicit rollback
restores the pre-edit HandoffSpec exactly; all 174 prior labels, 159 ordered checks, path literals and
all unaffected hash occurrences remain. The only retired digest literals are the two first-guard 45ca
self-comparisons; no replacement digest/arithmetic is added. All 909 other Haskell files remain exact.
Independent test/doc review passed. Lifecycle-model and unrepresentable-state docs change 15 nonempty/
17 physical lines; their separate response row and historical evidence remain unchanged.

The native warning-clean test target passed in 30.390786 seconds, exit 0 and empty stderr,
03:11:05.896340 to 03:11:36.286940 UTC, retaining the actual threaded RTS and fixed test/Cabal hashes.
The new 19-row case and changed request guard passed together, 2/2 in 1.13 reported/1.221964 wall seconds,
exit 0 and empty stderr, 03:13:05.303119 to 03:13:06.525083 UTC. The complete focused selection and full
four-command static gate remain owed.

Dated 2026-11-02 UTC final validation: the full 1,032-case focused selection passed in 183.48 reported/
183.580383 wall seconds, exit 0 and empty stderr, 03:13:06.608605 to 03:16:10.187866 UTC, with exact
source/Cabal hashes. The final sync audit passed in 11.671732 body/16.367499 outer seconds,
03:16:24.000474 to 03:16:35.672205 UTC.

All four linux-cpu static gate commands passed. Starting 03:17:15.997326 UTC, `cabal test all` from core
passed all 3,871 cases in 260.81 reported/291.424625 command seconds, exit 0, ending 03:22:07.462506 UTC.
`cabal test all` from demo passed its 165 cases in 1.44 seconds and the included 3,871 core cases in
258.32 seconds, exit 0/287.904890 command seconds, ending 03:22:03.942383 UTC.
`poetry run python -m hostbootstrap.check_code` passed in 1.297768 seconds, ending 03:17:17.337555 UTC.
The unfiltered supported `poetry run python -m hostbootstrap.test_all` passed 376 cases in 5.78 reported/
7.211379 command seconds, ending 03:17:23.251134 UTC, exit 0 and 100% line/branch coverage. Each full
Haskell leg recorded 26 conditional families, 62 supported outcomes and 21 genuine refusals, including
root 1/0, POSIX files 3/0 and Windows-unpaired names 0/1. Provider-live default wrappers passed as
NotRequested; the static gates claim no live provider, process exchange or hardware acceptance.

Final source/doc audit passed in 9.671760 body/14.671464 outer seconds,
03:22:30.799503 to 03:22:40.471265 UTC. All 910 Haskell files remain at snapshot
`a900ba138af014c475fb45e8183e5f98b241b5de154fcb649eef8fed832884fc`; the owned 885 remain at
`4af2152d3060d17f2f01d811f747be0850f372e11df432a29a24e801d97648df`. Only HandoffSpec changed;
909 other files, all 57 relocated production modules, all 616 compiler fixtures, component/project
metadata and Cabal d741 remain exact. The whole prior test source reconstructs after only the new case
and first-guard eight bindings/three assertions are reversed; the separate response guard and every
other owned control remain unchanged. All 95 held docs matched
`c8e65688ae9723dd4cf17aac87bd842795af23abf0f35cc143f1dfea78e0ac96`.
Canonical phase-1 covered-path measurement passed in 0.218304 seconds at 03:22:30 to 03:22:31 UTC,
exit 0, retaining `0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Cleanup and extra metadata checks passed in 0.371498 seconds,
03:22:51.530343 to 03:22:51.901836 UTC, with no test/probe children and original container StartedAt,
init, PID 1/7 and mounts retained. No failed gate, production edit or additional source rebase occurred.

After closing Sprint 13.37 and advancing the index to the next Active sprint (13.38 is already Done),
native DocValidatorSpec passed all 17 cases in 5.52 reported/5.597532 wall seconds, exit 0,
03:24:14.487287 to 03:24:20.084793 UTC. Scoped `git diff --check` also passed.

#### Remaining Work

None.


### Sprint 13.38: Closed rooted lifecycle response [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 280 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Define the complete bounded neutral response vocabulary paired structurally with one rooted request.

Sprint 13.39 owns cryptographic signing/verification, Sprint 13.40 owns transport, and Phase 17 owns
response production and semantics.

#### Deliverables

- The existing hidden `HostBootstrap.Handoff.Rooted` module adds this sprint's sole named contract: one
  non-indexed opaque `RootedLifecycleResponse` with exactly the closed variants `Opened`, `Prepared`,
  `Descend`, `Settled`, `FrameComplete`, `ReceiptRecorded`, and `Refused`; their exact discriminators are
  `opened`, `prepared`, `descend`, `settled`, `frame-complete`, `receipt-recorded`, and `refused`.
- `Opened` has exactly nine top-level frames: domain `hostbootstrap/rooted-lifecycle-response`, canonical
  Word64BE version 1, discriminator, 64 lowercase hexadecimal bytes for the digest of the exact canonical
  `OpenFrame` request, the nested admitted requester path, non-empty session and stage, a nonzero Word64BE next
  ordinal, and an exact 64-byte signature. Every other response has exactly eleven: the same first four,
  canonical path, session, response stage, response ordinal, exact 32-byte request nonce, one body, and the
  signature. Path has one to 256 non-empty UTF-8 components of at most 4,096 encoded bytes; session and stage
  are non-empty UTF-8 of at most 4,096 bytes.
- The one post-open body is at most 6 MiB. `Prepared` is exactly four nested non-empty frames for node,
  dependencies, operation gate, and projected gates, each at most 6 MiB and together at most 6 MiB;
  `Descend`/`Settled` are non-empty opaque bytes; `FrameComplete` is a non-empty lifecycle-report wire;
  `ReceiptRecorded` is exactly the 64-lowercase-hex digest of the matching `FrameComplete`; and `Refused` is
  non-empty UTF-8 of at most 4,096 bytes. The complete response is at most 7 MiB.
- The neutral exact-pair check accepts only `OpenFrame -> Opened`, `NextNode -> Prepared | Descend | Refused`,
  `SettleNode | DescendResult -> Settled | Refused`, `CloseFrame -> FrameComplete | Refused`, and
  `ReceiptConfirm -> ReceiptRecorded | Refused`; it checks the exact request digest, post-open path/session/
  nonce echo, and receipt-body/predecessor equality. An `OpenFrame` failure uses Protocol's existing outer
  `Refused`, never a rooted `Refused`; response stage and ordinal are structurally valid successor coordinates,
  not copies of the request coordinates.
- Exactly seven checked unsigned builders return only canonical `ByteString`; the separate private
  `rootedLifecycleResponseFromUnsignedKernel` strict-decodes those unsigned bytes and attaches an exact 64-byte
  signature. Strict signed decode/render and one closed total fold enforce canonical rerender,
  scalar/body/total bounds, and no trailing bytes without a caller-supplied signature-placeholder builder,
  lifecycle meaning, or lifecycle-report validation. The resulting opaque response is descriptive signed data,
  not authority, and may be retained as an ordinary value. No cryptography, Handoff facade, store, process,
  testing companion, or semantic/process/durable importer enters this neutral owner; Sprint 13.40 adds only
  the neutral Receiver-internal pair/path folds. This sprint changes neither Protocol nor Cabal, and Phase 17
  alone assigns body semantics, lawful successors, freshness, terminality, and replay.

#### Validation

Exactly three `HandoffSpec` source-guard cases pin all seven discriminators, exact 9/11 cardinalities, every
scalar/body/total bound, canonical rerender/no trailing bytes, the four-field nested `Prepared` body, seven
unsigned builders plus the sole signature-attaching kernel, absence of a signature-placeholder builder, the exact
request-family matrix, path/session/nonce echo, receipt/predecessor equality, outer-only open refusal, the
closed fold, single neutral owner, one-type budget, and absence of authority, cryptography, facade, storage,
testing-companion, or semantic/process/durable imports. Phase 17 owns semantic report/body, ordering, and
durable replay tests. The current guard retains its owned Rooted request/response attribution
`(504, 757, 253)`, paired Handoff definition evidence and the private signing capability's typed
section/three complete function-clause bundle, literal hashes, and all role, import, caller, producer,
datatype and pairing checks. The private owner's separate pure reread DATA is outside that capability
freeze; whole-private-file hash/size measurements remain dated attribution. The consumed outer singleton tag/field API is a Protocol contract;
the shared decoder, error datatype, renderer, and unchanged file complement are outside this response
owner. The historical landing measurements below remain dated evidence.

Dated 2026-08-12 production/API evidence: at landing `HostBootstrap.Handoff.Rooted`, the sole production
owner, measured 754 significant lines. The response adds 250 lines to the 504-line request/binding owner, within
the 280-line budget. The sprint adds no other production owner or runtime seam, and an independent
security/source audit passed. Its SHA-256 measured at landing is
`c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e`.

Dated 2026-08-12 focused validation evidence: the direct hidden-module warnings-as-errors compile and the
serialized combined library/test warnings-as-errors build passed; `HandoffSpec` passed 88/88 in 25.63 seconds;
the public compile-fail boundary passed 457/457 in 107.86 seconds; and `ProjectPlanSpec` passed 68/68 in 13.18
seconds. `DocValidatorSpec` passed 2/2 in 0.26 seconds. Canonical
`cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all 1,938/1,938 tests in 401.83
seconds; the suite reported PASS.

#### Remaining Work

None.

### Sprint 13.39: Rooted lifecycle response signing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 180 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Authenticate one structurally paired rooted response through the live root broker and independently installed
project key. The remaining changes are HandoffSpec coverage and proof precision, with zero production
delta and no new capability or parser route.

#### Deliverables

- This sprint adds no named type: the Handoff facade signs and verifies Sprint 13.38's exact
  `RootedLifecycleResponse`, while `Handoff.Rooted` stays the sole structural owner; this sprint changes
  neither Protocol nor Cabal.
- The signer has the fixed kernel shape `RecoverySigningKernel -> RootBroker ... -> ByteString -> ByteString ->
  IO (Either HandoffError RootedLifecycleResponse)`: its byte arguments are the exact request and canonical
  unsigned response. Under the live broker it strict-decodes both, repeats the neutral exact-pair check,
  validates the response body owned by this layer, signs, and attaches the real signature through
  `rootedLifecycleResponseFromUnsignedKernel`; no typed or raw placeholder-signature builder, generic unsigned
  renderer, arbitrary-message signer, callback, or caller-selectable domain/material is exposed.
- The signature transcript is exactly a frame of fixed domain
  `hostbootstrap/rooted-lifecycle-response/v1`, a frame of the live broker's installed verification-key digest,
  a frame of the exact complete canonical request, and a frame of the exact complete canonical unsigned
  response. Signing requires the matching live `RootBroker`; verification requires the independently installed
  key and exact request, then repeats canonical decode, request pairing, and signature checks. The public
  verifier has no separate project-identity argument; neutral requests carry no project identity.
- The facade requires `FrameComplete`'s body to pass the existing canonical lifecycle-report verifier before
  signing. Its installed-key verifier has the fixed key -> exact-request bytes -> complete-signed-wire -> CPS
  shape: it strict-decodes and structurally pairs first, verifies the exact transcript next, validates the
  `FrameComplete` report last, and only then enters the fixed response fold. The lower `Prepared`, `Descend`, and `Settled` bodies remain
  opaque until Phase 17, while `ReceiptRecorded`/`Refused` retain Sprint 13.38's exact digest/text rules.
- `Handoff.Internal` only specializes the existing unconstructible `RecoverySigningKernel` for this fixed
  response signer. No second capability, signing key, root broker, signature-attaching constructor, or semantic
  lifecycle authority escapes; an opaque response remains descriptive signed data. Phase 17 alone owns
  production, successor law, settlement, receipt mutation, and replay.

#### Validation

`HandoffSpec` cases cover public installed-key/domain verification and exact-request pairing,
signature/request/family/body cross-pairs and canonical-report refusal, and exact source/ownership guards
for the live-broker signer, specialized existing capability, no new named type, no generic unsigned/signing
surface, Protocol's one-way import contract, frozen handoff package rows, and three production owners.
Literal freezes retain the owned 119-significant-line, 6,323-byte response facade section and the existing
Internal capability's typed section and three complete clauses, plus Rooted section and definition-bundle
evidence. Separate pure reread DATA in the private owner is outside that capability freeze; its earlier
whole-file hash and 25-line size are dated attribution. This owner has no whole-Protocol or shared-complement
freeze. The package rows
are this phase's own — its module rows in the main library, plus that library's dependency set — rather than
the whole package description, because a sprint freezes what it owns (§ C). The guard retains the actual
119-significant-line, 6,323-byte response section and its fixed digest, named wrapper bundles, independent
capability-owner measurements, and all 13 binding-reader/26-line controls. Shared-facade totals and an
unchanged-file complement are not owned freeze subjects.

Dated 2026-11-01 attribution before the owned-scope adoption records a 3,521-line facade after excluding
the 26 reader lines. Baselines 3,085/12 and allowances 30/54/129 yield `(223, 13, 236)` against 240.
Those bookkeeping figures remain dated evidence; they are not the live budget oracle. This sprint's
actual landing measurement is the 139/180 figure below. The source guard preserves owned section and
definition-bundle hashes plus every independent authentication, role, caller, producer, ordering and
framing control without rebasing a whole shared file.

The "independently authenticates all seven closed families" case asserts only acceptance: deleting the
signature check in `withVerifiedRootedLifecycleResponse` leaves it green. Closure requires that, inside its
per-family loop, the same unsigned bytes signed with another seed and, separately, under the domain
`hostbootstrap/rooted-lifecycle-response/not-v1` each return `Left HandoffRootedLifecycleSignatureInvalid`
for every family.

The existing verification matrix accepts any Left. Replace assertRefused with a full expected
HandoffError per row, preserving all original wire mutations and controls. In particular, preserve the raw
"not a canonical lifecycle report" subject: its first eight bytes declare Word64
0x6e6f742061206361, so the actual refusal is HandoffWireTooLarge with the 8 MiB bound, not BindingMismatch.
Other semantic/framing failures pin their own complete typed constructor and detail rather than being
coerced to one error category.

The malformed Prepared-body and empty-Refused-detail rows must carry the same matching nextRequest in
response construction/signing and verification. Their existing closeRequest verification can mask deletion
of their body guards, even though decode currently precedes pairing. Preserve the existing cross-request
replay negative, correctly describing its current digest-pairing refusal before signature (its nonce also
differs). Add a separate response signed over the actual target request, correct family and all matching
coordinates, whose only defect is another request's digest. The exact refusal is BindingMismatch
"rooted lifecycle response names a different rooted lifecycle request"; deleting that digest check must
not leave a different mismatch to stop the row.

Drive the actual fixed signRootedLifecycleResponseKernel through the existing private
HandoffInternal.recoverySigningKernel route and a genuine live broker. Establish a matching signed
FrameComplete control first. Its four exact producer refusals are: correct-digest wrong family,
BindingMismatch "rooted lifecycle response rooted lifecycle response does not answer this request family";
matching-family response
with only foreign request digest, BindingMismatch "rooted lifecycle response names a different rooted
lifecycle request"; otherwise canonical eight-frame report with only domain/version changed,
BindingMismatch "the lifecycle report domain or version differs"; and unsigned FrameComplete plus one
raw trailing byte, BindingMismatch "rooted lifecycle response has more than ten unsigned rooted
lifecycle response fields". Compare the IO result normalized to unit with its complete expected Left,
without requiring Eq on an opaque successful response. The raw invalid-report framing negative remains
separate from this semantic report row.

Within every existing seven-family positive, sign the same accepted unsigned bytes with seed 94 and,
separately, with the matching seed 92 under hostbootstrap/rooted-lifecycle-response/not-v1. Each must
return exact Left HandoffRootedLifecycleSignatureInvalid. Retain all original accepted families and the
actual installed-key/transcript/pair/report checks. Fixtures derive their key/root origin from the genuine
broker; these neutral byte-level proofs claim no separate project identity or Phase 17 semantic/root-session
authorization.

Strict decoding leaves no independent accepted alternate encoding to reach final rerender inequality.
Use actual malformed/trailing grammar refusals rather than inventing a malformed opaque response or a
producer seam. No literal-budget cleanup remains: the shared 3521/(223,13,236)/240 arithmetic already
became dated comments in Sprint 13.26. Preserve actual 119-line/6323-byte/8017 response evidence,
thirteen readers/26 lines, scoped capability/path bundles, Rooted 757/55cede, all five Handoff bundles,
three Relay sections and every real caller/order/type/import control. The separate Done-13.38 response
253 guard remains unchanged.

Dated 2026-08-12 production/API evidence: the response-authentication additions to the public facade are
exactly the abstract `RootedLifecycleResponse`, `renderRootedLifecycleResponse`, the fixed
`signRootedLifecycleResponseKernel :: RecoverySigningKernel -> RootBroker ... -> ByteString -> ByteString ->
IO (Either HandoffError RootedLifecycleResponse)` signer, and
`withVerifiedRootedLifecycleResponse :: ProjectVerificationKey -> ByteString -> ByteString ->
(RootedLifecycleResponse -> result) -> Either HandoffError result`. The signer fixes the transcript to framed
domain `hostbootstrap/rooted-lifecycle-response/v1`, installed verification-key digest, exact complete
canonical request, and exact complete canonical unsigned response. The verifier independently parses and
pairs, verifies that transcript, validates a `FrameComplete` lifecycle report, and only then enters its fixed
CPS continuation. The value remains descriptive signed data rather than authority. This sprint adds no
production caller of the signer; its production callers are Phase 17's root-service endpoints in
`Handoff/Relay.hs`. Sprint 13.40's originating typed Relay operation is the verifier's production transport
caller. An independent security/source audit passed.

Dated 2026-08-12 landing production delta is 139/180 significant lines: `HostBootstrap.Handoff` +126,
`HostBootstrap.Handoff.Internal` +13, and the structural owner `HostBootstrap.Handoff.Rooted` +0. Their
respective SHA-256 hashes measured at landing are
`6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5`,
`305dc09a9e9ae617161f0b7ec35309aeb31d0152894988a8bc53f415cebca2bf`, and
`c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e`. This sprint left Protocol and Cabal
unchanged at `c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8` and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877` respectively.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test warnings-as-errors build
passed; `HandoffSpec` passed 91/91 in 27.91 seconds; the public compile-fail boundary passed 457/457 in
106.40 seconds; and `ProjectPlanSpec` passed 68/68 in 12.98 seconds. `DocValidatorSpec` passed 2/2 in 0.26
seconds. Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all
1,941/1,941 tests in 403.54 seconds; the suite reported PASS.

Dated 2026-11-02 UTC reconciliation: only the two existing response-verification runtime cases change,
112 nonempty/114 physical test lines at HandoffSpec SHA-256
`817a1f4f058641ff7f7f54f9b0d891bcec40adc0d1e4da2bd3567aee3b07e5a8`. Production, component metadata,
compiler fixtures and public APIs are unchanged. Each of the seven accepted unsigned families now has
separate wrong-seed/wrong-domain wires requiring the exact signature error. The existing refusal table
compares complete typed errors, retaining raw-report framing and every old mutation; only the two
malformed-body rows' request context is aligned for signing and verification. The new digest-only row
signs the actual Close request and changes no response coordinate except its foreign request digest.

The real fixed signer uses the existing private capability and genuine live broker. Its positive is
awaited, rendered byte-equal to the independent deterministic oracle, and independently key-verified
before four exact producer refusals run. The semantic-report negative changes only a valid eight-frame
report's domain, while the trailing unsigned grammar row exercises the real maximum-field collector.
No hidden Rooted import, capability producer, parser route or runtime seam is added. Every one of the
175 prior labels, 18 fixed hash occurrences and 159 ordered checks remains exact; the entire source
outside these two cases, including the 19-request matrix, separate Done-13.38 response guard and every
real source/role/caller/order/byte control, is unchanged. All 909 other Haskell files remain exact.
Reciprocal test/doc review passed. The two assigned docs change 20 nonempty/23 physical lines, retaining
the request row and all historical claims while naming the actual key-only API and validation precedence.

Native warning-clean test-target build passed in 25.956693 seconds, exit 0 and empty stderr,
03:33:19.548916 to 03:33:45.505450 UTC; actual rts_thr and fixed test/Cabal hashes were verified.
Both changed runtime cases passed in 0.05 reported/0.128607 wall seconds, exit 0 and empty stderr,
03:36:23.679413 to 03:36:23.808020 UTC. The full focused selection and four-command static gate remain
owed below.

Dated 2026-11-02 UTC final validation: all 1,032 focused cases passed in 170.80 reported/170.919523
wall seconds, exit 0 and empty stderr, 03:36:23.887072 to 03:39:14.805542 UTC, with exact test/Cabal
hashes. Independent review clarified only two prose claims before sync: the producer tail is one raw
byte and its family error contains the actual doubled wrapper prefix. No test or production edit/rerun
was required for those wording corrections. The final sync audit passed in 11.659048 body/16.462342
outer seconds, 03:42:10.327327 to 03:42:21.986377 UTC.

All four linux-cpu static gate commands passed. `cabal test all` from core passed all 3,871 cases in
284.26 reported/314.986703 command seconds, exit 0, 03:42:58.526132 to 03:48:13.547627 UTC.
`cabal test all` from demo passed its 165 cases in 1.43 seconds and the included 3,871 core cases in
283.13 seconds, exit 0/312.738291 command seconds, 03:42:58.532791 to 03:48:11.305224 UTC.
`poetry run python -m hostbootstrap.check_code` passed in 0.803310 seconds,
03:42:58.517276 to 03:42:59.358111 UTC. The unfiltered supported
`poetry run python -m hostbootstrap.test_all` passed 376 cases in 5.78 reported/6.779782 command seconds,
03:42:58.543309 to 03:43:05.361160 UTC, exit 0 and 100% line/branch coverage. Both full Haskell legs
reported 26 conditional families, 62 supported outcomes and 21 genuine refusals: root 1/0, POSIX files
3/0, Windows-unpaired names 0/1. Provider-live wrappers passed as NotRequested; these static results
claim no live provider, durable lifecycle or hardware acceptance.

Final source/doc audit passed in 9.553146 body/14.435454 outer seconds,
03:48:32.081714 to 03:48:41.634862 UTC. All 910 Haskell files remain at snapshot
`e54f2aeab1dfbe534896e226780e5806747963f3c17d976b147bc4fa080c6065`; owned 885 remain at
`804a30098499b521d9314dbe374ffd03797f3c3f805e3461ae0e1c787c9d71f3`. Only HandoffSpec changed;
909 other Haskell files, all 57 production modules, all 616 fixtures, Cabal d741 and both project files
remain exact. Source outside the two runtime cases reconstructs byte-for-byte; all old seven-family
positives, old literals, 175 labels, 18 fixed hashes, ordered arrays, 109 paths and every owned byte/
role/caller/order control remain preserved. No freeze, constructor, metadata or module boundary was
rebased. All 95 held docs matched
`d70bef1563c45ee520892cf8b946add932eeaba6ee61c06476cb9ca0995998e0`.
Canonical phase-1 covered-path measurement passed in 0.190826 seconds at 03:48:31 to 03:48:32 UTC,
exit 0, retaining `0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Cleanup/extra-metadata checks passed in 0.346360 seconds,
03:48:50.166638 to 03:48:50.512992 UTC, with no test/probe children and original container StartedAt,
init, PID 1/7 and mounts retained. No failed gate or additional source change occurred.

After closing Sprint 13.39 and advancing the index, native DocValidatorSpec passed all 17 cases in
6.05 reported/6.147405 wall seconds, exit 0, 03:49:56.168255 to 03:50:02.315625 UTC. Scoped
`git diff --check` also passed.

#### Remaining Work

None.


### Sprint 13.40: Rooted duplex relay adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 390 lines across two production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Adopt the closed rooted request/response bytes in the existing admitted package-private duplex relay as a
transport-only contract. This sprint constructs no recursive child and completes no successful rooted process
exchange.

#### Deliverables

- The admitted package-private serve loop carries one exact rooted request or response as the singleton field
  of the already-reserved outer tag; this sprint makes no change to `HostBootstrap.Handoff.Protocol`.
- Each hop prepends only its already-admitted requester component to a sealed external envelope in
  root-nearest-to-leaf order while preserving the inner request bytes. The envelope has one to 256 non-empty
  UTF-8 components of at most 4,096 encoded bytes each and is rejected before forwarding when that grammar
  fails. For `OpenFrame`, whose inner value contains only its nonce, this envelope is the sole ancestry input.
- One outstanding request alternates with one structurally paired response across every hop. Transport checks
  the strict canonical inner shape, exact request/response family and request binding, then returns the same
  inner bytes without interpreting a response body, signature, session token, stage, ordinal, predecessor, or
  lifecycle meaning.
- A received outer `Refused` and an exact signed rooted `Refused` are distinct uninterpreted transport
  outcomes: a relay propagates their exact bytes without translation or re-signing. Local validation may
  originate an outer refusal; a successful send closes the retained edge. The root endpoint performs
  structural validation (requester path and served provenance) and then answers through the
  `RootedLifecycleService` its root link is built with; this sprint supplies no such service, and Sprint 17.36
  owns the root service that answers.
- An intermediate relay holds no project signing key, `RootBroker`, protected store, root catalog, retained
  session path, session constructor, lifecycle authority, request/response constructor, semantic
  freshness/replay/receipt decision, or process owner. Phase 17 owns root response production, fixed-signer
  invocation, semantic session-path comparison, durable replay and receipt ordering, storeless execution,
  recursive call-site adoption, and the first real-process rooted exchange. This sprint adds no named type, public export, Cabal
  row, command caller, or process caller. Fixed upstream operations retain their existing authenticated
  ReceivedEdge and derive channel/request/route from it; local refusal success closes its monotonic
  transport progress without closing a pre-send validation failure.

#### Validation

`HandoffSpec` pins singleton outer fields, bounded requester-envelope construction, exact inner-byte
preservation, structural family/request pairing, one-request/one-response alternation, the root endpoint's
structural validation ahead of its service, and uninterpreted refusal propagation without importing the hidden
module. The public
compile-fail boundary retains `ImportHandoffRelay.hs`; private-source guards prove no relay-to-signer,
relay-to-store, semantic, durable, process, or recursive-command route exists. Run focused `HandoffSpec`, the
public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec`, then the canonical warnings-as-errors
`-j1` phase gate. The current change preserves the two named unchanged Relay byte sections from the
saved baseline; its relayRootedLifecycle section is the explicitly owned terminal-send bug-fix subject.
The old three-section concatenation remains dated pre-fix evidence, not an unchanged whole-file complement.
Retain independent Receiver semantic/type/import controls, Recovery/Rooted evidence, the
Receiver.Internal two-declaration typed/clause bundle adopted in Sprint 13.35, and the signing capability's typed
section/three complete function-clause bundle, and every transport, import, caller, producer and ordering
check. The private owner's separate pure reread DATA is outside that capability freeze; its whole-file
hash/size are dated attribution. It owns no whole-Protocol or unchanged shared-file complement
freeze; the original two-owner attribution and budget remain dated evidence. Phase 17 owns
every real-process rooted fixture.

Exercise receive-side parsing and provenance through a genuine admitted Receiver/proxy/rootBrokerLink
pipe dialogue, not a newly exported parser or hidden Rooted import. A valid OpenFrame request reaches the
real serveRootedLifecycle; the proxy changes only its sealed envelope path. Exact parent errors are
RelayHandoffFailure of HandoffBindingMismatch: 257 components, "the relay requester path exceeds the
protocol depth limit"; empty component, "the relay requester path contains an empty frame"; invalid UTF-8,
"the relay requester path contains invalid UTF-8"; declared width 4097 with short body, "the relay requester
path declares an oversized frame". Assert the genuinely propagated child refusal and await every worker.

Positive 256-component and actual 4096-byte-component envelopes must reach the existing root service
callback exactly once with their exact path/request. That callback is a DATA capture/counter and returns
a declared RelayEdgeNotPlanned sentinel; it proves grammar and structural service entry, not 256 real
nested processes or a successful lifecycle service. Invalid rows leave the service count zero. A path
starting at another child yields "the relay requester path does not begin at the exact admitted child".
An actual OfferRequest with only its encoded requestedParentFrame changed after public prechecks yields
"the requested parent frame is not the authenticated path origin", before admission/store mutation.
Preserve the complete/relative inner-path checks and their distinct provenance rules.

Dated 2026-11-02 pre-13.35 observation: the inherited budget guard combined literal Relay terms
2203/1852 with the shared live Receiver.Internal count 232 and prior 184, producing 399. It did not
measure this sprint's 390-line increment. Sprint 13.35 removes that unowned shared-file arithmetic and
the unchanged whole-Receiver complement pin as part of adopting receiver progress. Its fixed saved-baseline
typed/complete-clause bundle retains exactly the two Receiver.Internal rooted path folds, excluding shared
ReceivedEdge/progress; the three raw Relay sections remain exact. No replacement sum, subtraction or
current whole-file hash is introduced. This sprint's actual 275/390 landing evidence below remains dated.
The same case's forbidden-identifier row for `"System.Process"` can never match, because
`countHaskellIdentifier` compares single `lex` tokens; closure requires it replaced by
`countHaskellTokenSequence ["System", ".", "Process"]` over the section plus `importsModule
"System.Process"` over the whole `Relay.hs` and `Receiver/Internal.hs` sources. Its
no-rank-N-callback row tests `"forall"` against `words`, which misses `(forall`; closure requires
`countHaskellIdentifier "forall" transportOnly @?= 0`.

Relay can itself send Refused for a malformed upstream reply, then return its original non-peer error.
Retain actual successful terminal-send evidence so later report/relay/Receiver announcement is denied;
pre-send local errors keep progress open for their legitimate notification. Pass the existing actual
ReceivedEdge through the nine fixed upstream operations and their shared helper. Derive its retained
channel/request/route there; no generic channel observer, callback policy, new carrier type or authority
producer is needed. A fixed refusal operation gates closed progress, transmits on that retained channel,
closes monotonically on actual successful send under a short masked scope, and returns the original cause.
The received-await operation shares one pure reply classification with ordinary await, distinguishing a
local error requiring refusal from a consumed peer refusal/success. Preserve ordinary standalone-client
behavior, actual parent refusal causes, and arbitrary lifecycle callback restore . respond behavior.

The rooted raw receive path preserves outer refusal code/detail bytes independently of signed inner
Refused DATA. Its actual malformed/cross-request/unexpected-response sends must use the fixed edge-aware
refusal, while pre-send envelope/render failures remain nonterminal. Both generic await and rooted paths
need real malformed-upstream pipe cases: observe one actual self-sent upper refusal, then deny the
callback's first report and repeated relay use locally, then callback Left and exact upper EOF8/0 with
no echo. Separate downstream refusals still belong to their own channel.

The pre-send control must fail INSIDE the operation wrapper before transmission, so blanket closing of
any Left cannot pass. A genuine outer edge with a 4097-byte child frame is valid under Handoff's existing
nonempty/8MiB rules; Receiver admits it. Its derived OpenFrame route passes public request/key checks,
then renderRequesterEnvelope rejects that actual currentFrame with "the relay requester path contains
an oversized frame". Returning callback Left must still send the legitimate Receiver refusal followed
by EOF. No fake state, copied FSM or malformed opaque constructor is used. All peer dialogues, worker
results and cleanup remain bounded and awaited.

Dated 2026-11-02 UTC pre-edit owned-subject measurement: saved baseline
hostbootstrap-13-40-baseline-4gkf4vwv contains 25 texts/910 Haskell hashes. The exact saved HandoffSpec
requiredFrozenSourceSection reader was compiled with all 100 actual native Core-test arguments unchanged,
including threaded runtime/private thinning; only Temp targets/output paths were appended. Compile passed
in 1.993635 seconds, 03:54:29.091777 to 03:54:31.085400 UTC; measurement passed in 0.071885 seconds,
03:54:31.085507 to 03:54:31.157382 UTC, both exit 0 and empty stderr, with monitored source/metadata exact.
Saved/current Relay bytes were identical at SHA-256
`9659934cedfc514d1db9b84a5b20f06fd1a988b0015baaad7d29fcd98276c96c`.
The three named sections measured 1778/3438/2514 bytes and retained the pre-fix concatenated digest
`e6da9c59f8fffb13167a5773990d29e7c3543ad0dbbe20beaab7ce29f6a56fa0`.
The positively named unchanged receiveRootedLifecycleResponseThroughLink and serveRootedLifecycle sections
alone total 4292 bytes with fixed saved-baseline digest
`5e88ea61407d69faa7870e6be733169a644987b907ba090d708d6d5f8027591e`.
The middle relayRootedLifecycle section (3438 bytes/pre-fix digest
`730f6891540d30bbcd7b41916e92cbe1547357049243f981b02dc8fda11944ed`) is the necessary owned bug-fix
subject. Preserve its structural/path/refusal rules through the new runtime cases and explicit fixed
progress operations. Do not freeze an unchanged complement, rehash current whole Relay, or substitute
shared-file arithmetic. Both Internal path folds, five Handoff bundles, capability/raw-response/Rooted/
Protocol subjects and every independent transport/type/import/caller/order control remain unchanged.

Dated 2026-08-12 production/API evidence: the transport adds exactly 275/390 significant lines across the two
declared owners. `HostBootstrap.Handoff.Relay` grows by 227 lines from 1,852 to 2,079 and has SHA-256
`d751ce667d2b7e4871628028f3765954942d96d2a8c5017e87c90fb784d55006`;
`HostBootstrap.Handoff.Receiver.Internal` grows by 48 lines from 122 to 170 and has SHA-256
`0a481b39e02ef02f4e1c4e47ca306794e8727ff8e15f2baae6d579e6554a2834` at landing. This sprint left the Handoff
facade, neutral Rooted owner, Protocol, and Cabal file unchanged at, respectively,
`6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5`,
`c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`. The carrier adds no named type,
public export, Cabal row, semantic caller, process caller, signer, broker, store, catalog, or retained session
path. An independent transport/security/source audit passed.

Dated 2026-08-12 focused validation evidence (aarch64-osx, GHC 9.12.4): the serialized combined library/test
warnings-as-errors build passed; `HandoffSpec` passed 94/94 in 28.61 seconds; the public compile-fail boundary
passed 457/457 in 106.11 seconds; `ProjectPlanSpec` passed 68/68 in 12.80 seconds; and `DocValidatorSpec` passed
2/2 in 0.26 seconds. Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all
1,944/1,944 tests in 395.84 seconds; the suite reported PASS.

Dated 2026-11-02 UTC implementation/preflight evidence: the terminal-send change modifies only Relay,
209 changed nonempty/212 physical lines against the saved baseline, within the declared 390-line/two-owner
budget. Its frozen SHA-256 is
`09f8c1363ddb60f31ed34c52b44a4e79729b29e9efd3c79ff31df174a578159d`.
Receiver.Internal and the Handoff/Protocol/Rooted/Recovery owners, Cabal file and both project files remain
byte-identical. The two named unchanged Relay sections retain their measured 4292-byte saved-baseline
bundle. The three assigned architecture docs change 16 nonempty/18 physical lines and pass independent
implementation review. Native Windows `C:\ghcup\bin\cabal.exe build all` from core passed in
18.218030 seconds, 04:01:48.397602 to 04:02:06.616010 UTC, exit 0 and empty stderr; production and package
metadata stayed exact through that run. Independent production review passed. Relay-only Linux sync
passed in 0.883478 seconds at 04:03:09.303579 to 04:03:10.187062 UTC, leaving the other 909 Haskell files
at the closed prior-sprint snapshot. Linux core `cabal build all` passed in 20.346223 seconds,
04:03:13.9991343 to 04:03:34.3809680 UTC, exit 0. These record Main preflights only; test/gate evidence is owed.

Dated 2026-11-02 UTC closure evidence (Windows native focused gate plus retained x86_64 Linux host
static gate, GHC 9.12.4/Cabal 3.16.1.0): HandoffSpec changes 257 nonempty/263 physical test lines,
SHA-256 `04d99a69b73fa8f963d9457a3d8ada7ba973a02925a57b0b231bc38d17414fe2`.
Its four new cases are "the actual root parses requester path limits before its DATA service",
"the actual root refuses another requested parent before edge admission", "a real self-sent Relay refusal
closes the first report and repeated parent operation", and "a genuine pre-send envelope failure inside
the fixed Relay wrapper leaves notification live". Their eleven scenarios passed 4/4 in 0.31 reported /
0.393389 wall seconds, 04:05:49.557681 to 04:05:49.951069 UTC, exit 0 and empty stderr. The seven path
rows include exact 256-component/4096-byte service captures with a declared sentinel refusal; they establish
structural grammar/service entry only. Invalid rows never enter the service. The other-parent row retains
the admission count and full protected-state image. Generic and rooted self-sent refusal rows observe the
real refusal then deny the first report and repeated relay request before exact EOF; the admitted 4097-byte
child control fails inside the wrapper before sending and still announces Receiver's legitimate refusal.

Native `cabal build hostbootstrap-core:hostbootstrap-core-test` passed in 29.521430 seconds,
04:05:02.168290 to 04:05:31.690357 UTC, exit 0/empty stderr, with the actual linked rts_thr runtime.
The combined focused pattern for HandoffSpec, public compile-fail boundaries, indexed project-plan
foundation and DocValidatorSpec passed all 1036 in 177.04 reported/177.151062 wall seconds,
04:05:50.029638 to 04:08:47.179615 UTC, exit 0/empty stderr; all monitored sources stayed exact.

All four canonical host static commands passed on the retained x86_64 Linux gate host:

- Core `cabal test all`: 3875 tests, 263.08 reported/298.698972 command seconds, exit 0,
  04:08:59.1108298 to 04:13:57.8508016 UTC.
- Demo `cabal test all`: 165 demo tests in 1.68 seconds plus all 3875 included core tests in 261.55
  seconds, 303.854888 command seconds, exit 0, 04:08:59.1198342 to 04:14:03.0174350 UTC.
- `poetry run python -m hostbootstrap.check_code`: exit 0, 1.263266 command seconds,
  04:08:59.1198342 to 04:09:00.4275691 UTC.
- `poetry run python -m hostbootstrap.test_all`: 376 tests in 5.80 reported/7.210547 command seconds,
  exit 0, 100% line and branch coverage, 04:08:59.1198342 to 04:09:06.3741182 UTC.

Independent production, test-preservation, reciprocal and documentation reviews passed. An explicit
rollback of only the four new cases/helpers, defaulted DATA endpoint, eight mechanical private-call
literals and owned guard restores the prior HandoffSpec exactly. All 175 old labels, 109 paths and other
fixed controls remain; the only fixed-digest replacement is the positively premeasured two-section bundle.
The final 910-Haskell-file aggregate is
`4c2f9c72fee4def39c11aca25c8bda75146afc11c5edf57cf311331ecd0bf4ad`, and the 885 owned-file aggregate is
`4446b0c5af853341a076553c5c791fde14db6d5a080b3a69ff5840a232cea753`.
Only Relay and HandoffSpec differ from the saved baseline: the other 908 Haskell files, 616 compiler
fixtures, all 56 other relocated bodies, package/project metadata and absent old homes remain exact.
All five Handoff bundles, capability and two path-fold bundles, raw response and other independent
transport/type/import/producer/caller/order controls remain intact. The 95 held documentation aggregate is
`5f0576f980547050021644652c3a9683fe8f948516c4e9b653d7afd2286be929`.
Both Linux suites report all 26 conditional families, 62 supported/21 refusal cases, including root 1/0,
POSIX 3/0 and the genuine unpaired Windows row 0/1. Providers not requested establish no live acceptance.

Final source/docs audit passed at 04:14:28.865987 to 04:14:37.981630 UTC in 9.115641 body/13.851702
outer seconds. The compiled current phase-1 covers measurement passed in 0.182976 seconds at 04:14:28 to 04:14:29 UTC,
retaining `0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Process/metadata cleanup passed in 0.358505 seconds, 04:14:49.458454 to 04:14:49.816952 UTC: the original
retained container start, init, PID 1/7 and mounts remain, with no test/probe children. This closes the
sprint's static gate; the phase's separately declared focused-plus-`cabal test all -j1` gate remains due
at phase closure.

Closed-status native DocValidatorSpec passed all 17 in 5.29 reported/5.372383 wall seconds,
04:16:00.735433 to 04:16:06.107784 UTC, exit 0/empty stderr. Scoped `git diff --check` is clean.

#### Remaining Work

None.


### Sprint 13.41: The frame-child entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/Spec.hs`
**Production budget**: at most 400 changed nonempty lines across the three production owners above
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/build_and_run_model.md`, `documents/README.md`

#### Objective

Let a process of this binary recognize that it is the one on the far side of a frame crossing, so the
channel this phase already frames has an end that can be reached. The crossing carries an opaque transaction
and answer; interpretation belongs to the object's owning phase. Recursive lifecycle integration remains
owned by the recursive-lifecycle-command phase.

#### Deliverables

- One total pure classifier over argv decides whether this process is a frame child before the parser.
  Its value carries no coordinate, path, authority, caller-selected action or ProjectSpec extension route.
- runCLI reads argv once and retains its complete six ordered pre-parser entries: installed identity,
  exposure relay, working-directory wrapper, shipped command, forward lifecycle child and frame child,
  followed by the parser. The header names their actual effects and absence from help. Preserve runCLI's
  complete existing body; an exact comment-stripped token guard holds the complete dispatch.
- The marker names nothing an operator could usefully type and refuses unless standard input/output decode
  as the protocol channel. Its exact and dash-stripped spellings cannot enter the parser's option stream.
- The existing transaction/outcome tags each carry one field in Protocol's strict vocabulary. Retain the
  tag/codec and scoped acknowledgement controls while fixing shared stdio; introduce no whole-Protocol
  digest, unchanged complement or sibling-size arithmetic (section C).
- Transaction brackets one process on a dispatch from the lift fold and uses the existing ChildGroup
  platform row and descriptor cleanup. Remove the unused CPP pragma and no-op handoffChannel launch
  timeout/dead diagnostic. A crossing has no deadline; caller cancellation still ends the tree. The
  Windows Job Object row remains Sprint 13.50's. Receiver and ChildGroup remain unchanged in this sprint.
- The shared private-stdio bracket closes every duplicate already acquired when a later duplicate or
  null-sink acquisition fails. Partial global redirection attempts restoration of both saved globals before
  closing duplicates, retaining the existing best-effort handling of restoration IO errors. Normal callback
  success, exceptions and cancellation retain the existing outer restoration.
- The transport interprets no transaction. A declining interpreter sends a refusal. A decoded wrong-tag
  message receives Refused under its decoded id before returning the original Left. An ordinary interpreter
  IOException receives code "unavailable" and fixed detail "the frame interpreter failed", then that same
  exception is rethrown. Catch only that class around interpret; channel/cleanup errors and asynchronous
  interpreter/notification exceptions keep their existing propagation. The near-side total answer reader
  distinguishes outcome, refusal and wrong request identity without launching a process (section NN).

#### Validation

HandoffSpec retains the pure classifier's accepted/rejected argv shapes and the total readFrameAnswer value
cases. Its real-process cases re-invoke the actual suite executable using the existing frame entry APIs.
Run focused HandoffSpec, actual public compile-fail boundaries, ProjectPlanSpec and DocValidatorSpec, then
all four canonical host static commands. Record actual counts, outcomes and changed production lines.
The phase's separate declared gate remains owed at phase closure.

- Match the complete runCLI binding/argv read/six dispatches/parser fallback exactly using SourceGuard's
  actual definition tokens before its where block, beginning with the installed-identity condition.
  Retain argv-read and forbidden-environment controls. The baseline already lacks the old Transaction260
  equality; keep it absent rather than adding another whole-source size pin.
- Search the existing physical src/internal/app inventory for both full and dash-stripped marker string
  tokens. Retain the sole full-marker owner and forbid an optparse long literal even in that owner.
- The real crossing sends a cluster-exposure request with invalid field count, refused before host effects,
  and asserts exactly "frame child: the frame refused the transaction: unavailable: the cluster exposure
  request does not contain exactly three fields".
- Empty stdin, non-protocol bytes and a well-framed wrong-tag message each exit nonzero with the actual
  frame-child diagnostic. The wrong-tag case receives exactly one Refused frame echoing its decoded id.
  Raw two-field FrameTransaction bytes fail strict decoding with ProtocolExcessFields before a trusted
  message/id exists, so they produce a failing diagnostic and no protocol reply. Do not fabricate a decoded
  two-field message or redesign ProtocolError to satisfy an unreachable branch.
- A suite-only reinvocation obtains the opaque entry via classifyFrameChild and calls the existing public
  runFrameChildEntry/frameInterpreter with userError. Assert one exact Refused under the decoded id with
  code "unavailable"/detail "the frame interpreter failed", then confirm the same IOException's
  ioeGetErrorString outside the actual entry and nonzero exit. serveOneFrameTransaction stays private;
  no production test branch/export is added. This guarantees ordinary interpreter IO failures, not every
  synchronous exception. Preserve existing raw protocol diagnostic rendering.
- A real stdio-isolation process writes an ordinary stdout marker inside withPrivateProtocolStdio; it
  appears only on stderr, while the protocol outbound remains exact. A marker written after the bracket
  returns reaches the original stdout. Capture raw binary outputs, exact frames/remainder, exit and EOF;
  bound and await every process and reader. Source checks hold each acquisition cleanup and both-global
  rollback without fault injection or a new resource seam.

The runtime cases prove the actual Transaction child body. The complete runCLI joined routing is proved
by source shape here because the suite's own main is not runCLI; the recursive-lifecycle-command phase
owns its joined lifecycle execution. No successful rooted lifecycle exchange is claimed.

Dated 2026-08-18 production evidence (x86_64-windows, GHC 9.12.4): the entry adds 343/400 significant
lines across its owners and removes 63 from the receiver that now shares the isolation.
`HostBootstrap.Handoff.Transaction` is 275 significant lines with SHA-256
`a79ff17159608e65392de29817ea39e1463ce0832205d13e1f14f39fa94ae8b6`;
`HostBootstrap.Handoff.Protocol` grows by 63 to 526 significant lines and
`HostBootstrap.CLI` by 5 to 451. Their SHA-256 values are
`04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4` and
`ced91a317786e5c19f05bd14b52b70094fd7180a29774a79e3ee582d1e47d95a`, and
`HostBootstrap.Handoff.Receiver` is `514941f9d28ccb29ab6acb883f5f4797e6552842f9cc5e40c089684415544615`.
The entry names no protected store, broker link, installed identity, signing or verification key, project
spec, command authority, environment lookup, or second argv reader.

Dated 2026-08-18 validation evidence (x86_64-windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0):
canonical `cabal test all --ghc-options=-Werror` from `core/` passed 1,957/1,957 in 238.84 seconds;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

Dated 2026-11-02 UTC pre-edit baseline: 32 saved texts, 910 Haskell hashes and 616 compiler fixtures.
Transaction is `3f03c2d761fb6616489fa5dd32a51348944336ba3174cc34839772dfe9774774`, Protocol is
`224ee2cf44b9a8032b3a8ac077450d6dd7ce40bdf0568008c0714ae207ed212d`, CLI is
`f91b681ec039b72fa8b4aefa4c3a4818a73dc620ccc2a2f5a53edfe623b7a300`, and HandoffSpec is
`04d99a69b73fa8f963d9457a3d8ada7ba973a02925a57b0b231bc38d17414fe2`.
The actual reviewed scope is three production modules. Receiver, ChildGroup and the existing process-tree
bracket remain unchanged. No whole shared-file hash is introduced as a guard. The strict arity boundary,
actual six-entry dispatch and ordinary-IOException-only refusal policy are aligned before editing.

Dated 2026-11-02 UTC implementation/native Main preflight: 94 changed nonempty/97 physical production
lines across exactly three modules, within the 400-line/three-owner budget. Transaction changes 56/56 at
`f01a6b9e856f91cbe41d9b41968322ec30066ae6022b3bb5ab998fe177f54202`; Protocol changes 20/20 at
`772dfdd1d0a7e8ea0f8aabddb54c5ea132945666950d52eee6bf837b0b5be705`; CLI changes 18/21 at
`ecdaf1e6a1a01a514517b196a8f48368af6cbd695ef901f949c1e6b9e43d6f07`.
CLI from its module declaration onward, Transaction's spawned/process-shape/teardown sections, public
exports and strict Protocol wire API remain byte-identical. The three assigned docs change 44 nonempty/
47 physical lines, explicitly retaining best-effort restoration. Native Windows `C:\ghcup\bin\cabal.exe build all` from core passed in 6.375820
seconds, 04:22:01.281767 to 04:22:07.657547 UTC, exit 0/empty stderr, with frozen production and metadata
exact. Independent production review and revised documentation review passed. Production-only Linux
sync passed in 0.899897 seconds at 04:24:57.599152 to 04:24:58.499050 UTC, copying only the three
frozen owners and preserving the other 907 snapshot Haskell files. Linux core `cabal build all` passed in
11.951771 command seconds, 04:24:58.6618066 to 04:25:10.6488630 UTC, exit 0, compiling the actual
changed owners and linking the executable. These record Main preflights only; focused/full static
validation and final audits remain owed.

Dated 2026-11-02 UTC test/focused validation evidence: the initial native test build passed in
27.708255 seconds at 04:26:59.679972 to 04:27:27.388057 UTC, exit 0/empty stderr, actual rts_thr.
All 11 frame-entry cases passed in 0.96 reported/1.043330 wall seconds, 04:27:55.812572 to
04:27:56.855895 UTC. The first full focused run then failed one of 1040 cases in 180.80 reported/
180.901486 wall seconds, 04:27:56.934761 to 04:30:57.835142 UTC, exit 1: the existing dedicated-receiver
source case retained two old isolateGlobalStdio expected literals. Adopt only its actual three arguments
and both onException rollback calls while retaining all enclosing bracket, flush, redirect-order,
restoration and user-callback assertions. This is not a passing focused run.

The corrected HandoffSpec is `10e2975656e41676a4b6c3b3ffa7ec6fcb34418dce8ef5fce58afcf8803a8270`,
225 nonempty/232 physical changed lines; Spec is
`1f6726d039b16eb2d41dcb138090f36d0427f2b3853ed567d3b21617e24bb979`, 2/2, total 227/234.
Reversing exactly those two named literal lines restores the initial 694c5fac test freeze byte-for-byte;
the original suffix is otherwise exact. All 179 old labels, fixed hashes and ordered controls, 905
unrelated Haskell files and 616 fixtures remain exact. Independent reciprocal review and scoped diff checks
pass. An external audit initially scoped an IOException-only assertion over all Transaction and hit the
unchanged SomeException cleanup tail; limiting that assertion to the actual serve definition corrects the
audit, with no production change. Its intermediate audit pass is not final gate evidence. Rebuild, rerun
the corrected descriptor case plus frame-entry cases and all focused tests before the four-command gate.

Dated 2026-11-02 UTC closure evidence: after the two expected-literal corrections, the native test
rebuild passed in 26.774927 seconds, 04:32:59.236719 to 04:33:26.011482 UTC, exit 0/empty stderr,
with actual rts_thr and frozen sources/metadata exact. The corrected descriptor case plus all 11 frame-entry
cases passed 12/12 in 0.99 reported/1.087211 wall seconds, 04:34:11.440980 to 04:34:12.528186 UTC.
The complete focused HandoffSpec/public compile-fail/indexed project-plan/DocValidatorSpec pattern passed
all 1040 in 175.22 reported/175.381715 wall seconds, 04:34:12.609994 to 04:37:07.990634 UTC,
exit 0/empty stderr. This supersedes the earlier failed focused run as closure evidence.

The four new HandoffSpec cases are "the actual frame child refuses malformed streams and a decoded wrong
tag", "an interpreter IOException sends one refusal and rethrows the original exception", "private
protocol stdio isolates ordinary output and restores stdout", and "private stdio acquisition and both
global redirects retain cleanup". They cover four malformed binary process scenarios, exact decoded-id
refusal bytes, original IOException confirmation and exact stdio isolation/restoration. The existing real
crossing now asserts the known pure cluster-exposure refusal; the complete six-entry source-token guard,
physical full/dash-stripped marker census and narrow cleanup guards pass. These prove actual Transaction
child behavior and the CLI's source join, without claiming a joined lifecycle exchange.

All four canonical host static commands passed on the retained x86_64 Linux gate host, GHC 9.12.4/
Cabal 3.16.1.0:

- Core `cabal test all`: all 3879 tests in 256.45 reported/293.526480 command seconds, exit 0,
  04:37:56.2692156 to 04:42:49.8316849 UTC.
- Demo `cabal test all`: 165 demo tests in 1.40 seconds plus all 3879 included core tests in 260.55
  seconds, 302.053148 command seconds, exit 0, 04:37:56.2832768 to 04:42:58.3732394 UTC.
- `poetry run python -m hostbootstrap.check_code`: exit 0, 1.271340 command seconds.
- `poetry run python -m hostbootstrap.test_all`: all 376 tests in 6.14 reported/7.277534 command
  seconds, exit 0, 100% line and branch coverage. Both Python legs began at 04:37:56 UTC.

Independent production, revised-documentation, test-preservation and reciprocal reviews passed. The final
910-Haskell-file aggregate is `7e1df2f76d6f11a7c270a52b1e06c1caef146514f41afb0cf1e39360038435e4`;
the 885 owned-file aggregate is `b6fd1fceaf7fec90b2fc76aed81ae60ca54b1abb280b0b9bd71797b829e10534`.
Only three production and two test files differ from the immutable baseline. The other 905 Haskell files,
616 compiler fixtures, all 56 other relocated bodies, all 57 absent old homes, Cabal/project metadata,
97 export pins, 109 paths and all fixed hash multiplicities remain exact. All five Handoff bundles,
capability/two path-fold bundles, raw response/readers and the Relay 4292-byte saved bundle remain intact.
All 179 old labels remain in order, with four new cases; the old suffix changes only the two explicitly
reviewed stdio literals, whose reversal reproduces the initial 694c5fac test freeze. The old CLI fragment
array is replaced by its complete exact definition-token check, with read/environment/ownership checks
and the separately owned CLI>=424 proxy retained. The 95 held-document aggregate is
`5d41ec3ac1ce6cc0a56f27f9dabf3adcae7ce38640f2f51e8d59fece418dc801`.
Both core-suite outputs retain all 26 conditional families, 62 supported/21 refusal cases, including root
1/0, POSIX 3/0 and genuine unpaired Windows 0/1. Providers not requested establish no live acceptance.

Final source/docs audit passed 04:43:24.448429 to 04:43:33.780947 UTC in 9.332518 body/14.170335 outer
seconds. The compiled phase-1 covers measurement passed in 0.192939 seconds (0.523695 wrapper) at
04:43:24.306262 to 04:43:24.867701 UTC, retaining
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Process and additional metadata audit passed in 0.340469 seconds, 04:43:42.585743 to 04:43:42.926207 UTC:
original retained start/init/PID 1/7 and mounts stay intact, with no test/probe children. These close the
sprint's four-command static gate; the separately declared phase gate remains due at phase closure.

The initial closed-status DocValidator run failed one of 17 at 04:44:41.534086 to 04:44:47.820211 UTC
(6.21 reported/6.286163 wall seconds): this Active phase had no Active sprint after all remaining sprints
were left Planned. Starting Sprint 13.42's actual planning work corrects that metadata. The closed-status
rerun passed all 17 in 5.55 reported/5.625517 wall seconds, 04:45:14.406125 to 04:45:20.031611 UTC,
exit 0/empty stderr. Scoped `git diff --check` is clean; no source change was needed.

#### Remaining Work

None.


### Sprint 13.42: Rooted has one measured test-only compiler route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs` (one comment only)
**Production budget**: no production Haskell edits, relocations or new types
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/architecture/unrepresentable_state.md`

#### Objective

Give the existing private Rooted owner the same explicit, measured test-only compiler route as the four
already selected implementation modules. Coordinate tests can then reach the actual kernels while ordinary
Main-only consumers still cannot import them. The following seven sprints each introduce one coordinate type;
this sprint introduces none.

#### Deliverables

- Add only Handoff.Rooted to core-test's existing implementation-unit mixin, selecting five named modules.
  Retain the same implementation unit, exact private dependency, all 52/5 registrations, 57 physical homes,
  14 roots, 97 export pins, Main's 104 public modules and existing reexports. Never expose the whole unit.
- Move only Rooted from the test-withheld inventory into the exact allowed test inventory. The actual
  compiler module map shows all five selected origins and the remaining 18 withheld implementation origins;
  noncolliding same-context hidden negatives become 17. Preserve the separate DATA identity controls.
- Keep the canonical Main-only ImportHandoffRooted fixture, registration and named refusal unchanged.
  Replace only its selected-test-context hidden expectation with an actual-context success using that same
  file. Keep actual compiler-context resolution and argument validation unchanged.
- Add an actual selected-context positive unifying Rooted's opaque payload/response types with the existing
  public Handoff types, plus a value-level decode/render identity through the real existing APIs. Introduce
  no producer, parser export, production test branch, PackageImports or manually widened compiler context.
- Update the precise test-source import rule and current testing docs for five selected/18 withheld owners.
  Earlier four-owner gate results remain dated evidence. All production bytes, wire goldens, cryptographic
  subjects and scoped capability/path/transport/source controls remain exact.

#### Validation

Before changing Cabal, run the existing canonical Rooted import in both actual selected-four and Main-only
contexts; retain named hidden-module diagnostics, actual unchanged compiler argv and frozen metadata.
After building the real changed test component, the same file compiles in its actual selected-five context
and still refuses in the ordinary Main-only context. Measure all five selected module origins, all remaining
withheld origins and the DATA distinction using the existing resolver, not hand-added package flags.
Run the typed identity/value positives, component/import/source controls, full focused HandoffSpec/public
compile-fail/ProjectPlanSpec/DocValidatorSpec and all four host static commands before the next sprint.
Record actual commands, counts, compiler argument provenance, outcomes and preserved production hashes.
The phase's separately declared gate remains owed at phase closure.

Dated 2026-11-02 pre-edit baseline: 35 texts, 910 Haskell hashes and 616 compiler fixtures, captured before
this visibility change. HandoffSpec is `10e2975656e41676a4b6c3b3ffa7ec6fcb34418dce8ef5fce58afcf8803a8270`,
CompileFailSpec is `44d0386056bae6a112d2313dc42018a664fee60277712ed3521749c0365cf3a4`, and Cabal is
`d7415b69aea89fa59f46ed895f67eb82b1b7a9ac67cc73b916b3f19564d39260`.

Dated 2026-11-02 UTC BEFORE visibility evidence: canonical ImportHandoffRooted.hs is 168 bytes at
`9a492ecf20a91cf2dc4d1a96e572c4dce8041f967a5ee621a599d729e4086331`.
The unchanged actual test binary's two canonical cases passed in 0.523850 seconds, 04:48:39.470747 to
04:48:39.994576 UTC, validating its real executable/plan/build-info path and all 100 native compiler args.
Replaying the exact existing handoff-compiler route with those unchanged arguments and its normal Temp
suffix failed as expected, GHC exit 1/GHC-87110, in 0.105027 seconds at 04:49:15.810755 to
04:49:15.915770 UTC. The Main-only public resolver was measured with a Temp copy whose export header
alone changed; actual resolver/helper bodies stayed exact. Helper compilation passed in 6.509860 seconds,
then measurement passed in 0.235681 seconds at 04:49:51.470209 to 04:49:51.705850 UTC, both helper
exits 0/empty stderr, with its inner canonical compiler exit 1/GHC-87110. Both compiler diagnostics name
HostBootstrap.Handoff.Rooted as a member of hidden package
hostbootstrap-core-0.1.0.0:handoff-implementation-internal. Cabal, both projects, fixture, compiler spec,
HandoffSpec, plan/build-info/setup metadata and actual binary hashes remained unchanged. No package flag,
resolver body, getExecutablePath result or test source was rewritten to obtain this evidence.

Dated 2026-11-02 UTC implementation/component/AFTER evidence: production Haskell is unchanged.
Cabal changes one line at `9e675396b54398109557eb64dcae5c7ab70406309694911698868e9c1ea49fbe`;
CompileFailSpec changes 26 nonempty/physical lines at
`2efc714c72a3eca854b71280cbe8332ed2c31982201d3cc7c095eca9622b71b4`; HandoffSpec changes 29/29 at
`1a61cab36ce60351e71000b6c0e620242b807a7a0afa27db21f3cdce1f6644d2`, total 56/56 including metadata.
All 616 fixture bytes and 186 production Haskell files remain exact. Two visibility labels mechanically
change four to five; the other old labels remain, with one new case, 184 total. The compiler-context case
count is unchanged. Exact rollback restores both prior test sources and Cabal. The two docs change 16/16.
Independent implementation, compiler-context, test and documentation reviews pass.

Native `cabal build hostbootstrap-core:hostbootstrap-core-test` passed in 65.576549 seconds,
04:59:27.729678 to 05:00:33.305824 UTC, exit 0, actual linked rts_thr; Cabal emitted only its dated
package-index-age warning. Frozen sources, Rooted and project metadata remained exact. The six direct
visibility, genuinely signed value identity, opaque type identity and canonical private/public-context
cases passed in 3.41 reported/3.543646 wall seconds, 05:01:52.329248 to 05:01:55.872869 UTC,
exit 0/empty stderr. The new value case uses the real offer/signer/grant/public verification and existing
Rooted/public codecs, with no constructor, producer, parser export or accepting adapter added.

The actual running binary's AFTER compiler selector passed all 49 controls in 4.21 reported/4.297902 wall
seconds, 05:01:58.454735 to 05:02:02.752567 UTC, exit 0/empty stderr. This includes six inline type
positives, the unchanged canonical Rooted fixture success, five parser controls, 17 hidden imports,
the DATA typed negative, 18 withheld origins and the ordinary Main-only Rooted refusal. Raw GHC against
the same 168-byte fixture in the actual selected-five context passed exit 0/empty stderr in 0.132672
seconds, 05:03:26.515179 to 05:03:26.647826 UTC. Raw module-map measurement passed in 0.175883 seconds,
05:03:26.648495 to 05:03:26.824346 UTC; Rooted is the same implementation-unit origin, marked hidden
package plus actual package-flag exposure. The Main helper passed in 0.372594 seconds,
05:03:26.824495 to 05:03:27.197071 UTC, with its inner canonical GHC exit 1/GHC-87110 and the exact
unchanged named hidden-package diagnostic. All 100 actual native compiler arguments remain present;
only argument 32 changes, the Cabal-generated selector adding Rooted. No other argument, unit or package
DB changes. Actual installed Main still exposes 104 modules. All frozen source, fixture, component
configuration, plan/build-info, binary and installed-conf hashes stayed exact through those measurements.

Linux component-only sync passed in 4.141072 body/4.242852 outer seconds at 05:01:08.748177 to
05:01:12.889249 UTC, copying only the two tests and Cabal. Its actual
`cabal build hostbootstrap-core:hostbootstrap-core-test` passed in 59.500536 seconds,
05:01:32.052940 to 05:02:31.591705 UTC, exit 0, actual linked rts_thr. Actual Linux AFTER metadata
contains 102 compiler arguments and the exact five-module selector; its earlier full-argv output capture
was truncated, so it is not used as a complete before/after delta. The complete native 100-argument
measurement above supplies that delta. Focused/full static validation and final evidence audits remain owed.

The first full focused run failed one of 1041 tests in 181.08 reported/181.204626 wall seconds,
05:01:55.964065 to 05:04:57.167581 UTC, exit 1/empty stderr: the older hidden-module owner case still
listed Rooted beside Completion and Receiver.Internal in its HandoffSpec import ban. Remove only that
obsolete Rooted item, retaining the two genuinely withheld bans and every other owner/caller/type/producer
assertion; the separate exact five-module/component rule holds the authorized route. HandoffSpec is now
`2e316adc842457e96f98fae924b8b187db6acc67075c43711796ca6b48016b93`, 30/30 lines; reinserting only
that item restores the initial 1a61cab3 freeze exactly. Independent review and the scan for remaining stale
Rooted bans pass. One ProjectPlanSpec comment now says "exact selected test view" instead of "four-module
test view"; its function and trusted Main-import inventory remain byte-identical. This comment changes 2/2
nonempty/physical diff lines. Total test/metadata footprint is 59/59, with no production Haskell or fixture
change. The initial focused run is not passing closure evidence; rebuild and rerun the corrected owner case,
visibility controls and full focused suite before the four-command gate.

The corrected native component rebuild passed in 43.641121 seconds, 05:08:53.185574 to
05:09:36.826427 UTC, exit 0/empty stderr, with actual linked rts_thr and frozen sources exact.
The corrected owner case plus all six direct visibility controls passed 7/7 in 6.69 reported/6.802505
wall seconds, 05:10:15.517396 to 05:10:22.319855 UTC, exit 0/empty stderr. Independent reviews confirm
the sole Rooted-ban item removal and the comment-only ProjectPlanSpec correction; all other logic and
control bytes remain unchanged. The full 1041-case focused rerun and four-command gate remain owed.

Dated 2026-11-02 UTC closure evidence: the corrected full focused HandoffSpec/public compiler/
indexed project-plan/DocValidatorSpec run passed all 1041 in 167.92 reported/168.046368 wall seconds,
05:10:22.418404 to 05:13:10.463742 UTC, exit 0/empty stderr, with frozen metadata/source hashes exact.
The earlier failed 1041-case run remains recorded separately and is not closure evidence.

All four host static commands passed on the retained x86_64 Linux gate host, GHC 9.12.4/Cabal 3.16.1.0:

- Core `cabal test all`: all 3880 tests, 277.94 reported/325.153827 command seconds, exit 0,
  05:13:24.2771802 to 05:18:49.4684788 UTC.
- Demo `cabal test all`: 165 demo tests in 1.82 seconds plus all 3880 included core tests in 272.45
  seconds, 333.461532 command seconds, exit 0, 05:13:24.2771802 to 05:18:57.7764281 UTC.
- `poetry run python -m hostbootstrap.check_code`: exit 0 in 1.210438 command seconds.
- `poetry run python -m hostbootstrap.test_all`: all 376 tests, 5.89 reported/7.285997 command seconds,
  exit 0, 100% line and branch coverage. Both Python legs began at 05:13:24 UTC.

Final read-only source/docs audit passed at 05:19:28.467856 to 05:19:41.167766 UTC in 12.699910 body/
17.703398 outer seconds. The 910-Haskell-file aggregate is
`3a531d1631787aecca0c4b1d9a3ab181beade628d9a690e4d9f42d179256be21`; the 885 owned-file aggregate is
`e5411d9932f020102ade5d855c4059956e2d75a1f27bd2ba0f6fa2842bf8ecf1`; the 95 held-document aggregate is
`d715d13adc23cbb0db6e8b869f939b14bdfaed1b5f7fd91c9493abb0c0e516ce`.
All 907 unrelated Haskell files, all 186 production files and 57 relocated bodies, 616 fixture names/bytes,
97 export pins, fixed hash multiplicities, 158 ordered arrays under the same reader and 109 path controls
remain exact. The three test-source changes reverse exactly through their declared scopes; Cabal reverses
by removing only the Rooted selector line. All five Handoff bundles, capability/path-fold/raw-response/
Relay subjects, current Rooted bytes and independent public/import/producer/type controls remain intact.
No resolver, runner, matcher, package DB, public Main exposure or production API changes. The selected-five,
withheld-18, noncolliding-17 and separate DATA-origin evidence all pass. Both full suites retain 26 conditional
families, 62 supported/21 refusal cases and root 1/0. Providers not requested establish no live acceptance.

The compiled current phase-1 digest query passed in 0.208041 seconds (0.538885 wrapper),
05:19:28.304542 to 05:19:28.880973 UTC, retaining
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`.
Final process/additional-metadata audit passed in 0.369903 seconds, 05:19:51.409241 to 05:19:51.779138 UTC:
original retained start/init/PID 1/7 and both mounts remain intact, with no test/probe children. This closes
the sprint's static gate; the separately declared phase gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 in 5.40 reported/5.484008 wall seconds,
05:21:32.299147 to 05:21:37.783118 UTC, exit 0/empty stderr, with the following sprint Active for its
actual planning work. Scoped `git diff --check` is clean.

#### Remaining Work

None.


### Sprint 13.43: Payload digest is one checked coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across Rooted and Handoff; exactly one new named type
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give the payload-digest input role one checked opaque PayloadDigest accepting exactly 64 lowercase hexadecimal
characters. It is inert DATA, not signing, session or command authority. The following child-config role and
post-open response roles remain their own sprints. The five post-open request builders, nonce-only OpenFrame,
Opened response and broader descriptive fold-return adoption belong to Sprint 17.73's bounded caller work.

#### Deliverables

- Rooted exports abstract PayloadDigest, mkPayloadDigest :: Text -> Either Text PayloadDigest and the total
  payloadDigestText eliminator. Keep the constructor hidden; ordinary Eq/Show support describes inert DATA.
  Reuse the existing canonical requireDigest payload check and preserve current error precedence. A
  monomorphic newtype receives no fictitious parameter-role annotation.
- The existing rootedPayloadBindingKernel and renderRootedPayloadUnsignedPartsKernel payload arguments,
  retained payload field and rootedPayloadDigestKernel getter use PayloadDigest. Adopt the existing payload
  decoder/unsigned/render helpers coherently, without adding an accepting raw compatibility kernel or parser.
  ChildConfigDigest is not introduced here; its current Text argument remains the next sprint's subject.
- Handoff's two existing validation helpers perform their original broker/kind/byte/edge checks before
  smart-wrapping the actual computed SHA and returning a typed payload coordinate in the existing tuple.
  Retype the existing rootedUnsigned helper and eliminate only at the existing public Text description
  projection. Preserve both signer clauses and all five frozen Handoff function bundles byte-for-byte.
- Adopt the four positively premeasured unchanged subjects below through the existing actual signature,
  complete-clause and Aeson readers. Payload representation/getter/decoder/unsigned/kernel declarations are
  this sprint's explicitly owned changed subject and are excluded from those preservation bundles.
- Retire the three unowned whole-Rooted55cede pins, shared757/504/253 arithmetic and self-comparisons,
  payload148/header22/facade136/147+170=317 attribution and global data3/newtype0 equality as live guards.
  Keep their prior results dated. Do not hash the current whole file or an unchanged complement, subtract
  the type delta, or replace those totals with another global count.
- The Recovery facade's earlier 101-line attribution also contains the private validator whose payload
  tuple is this sprint's changed subject. Retire that live size equality as dated evidence, retaining
  neutral Recovery's 78-line owned codec and every semantic/import/producer check. Freeze only the three
  unchanged Recovery wrapper declarations measured below; do not repin 101 to 102 or use a complement.
- Retain exact public Main/private-unit boundaries, current five-module test selection, independent Rooted
  import/export/type/producer/caller/order checks and existing wire goldens. The request/response shapes,
  request31, response31 and shared7/constants13 are unchanged during this payload adoption; later response
  input adoptions declare their own changed declarations before any affected preservation subject changes.

#### Validation

Add selected-five real-kernel positives and RawTextAsRootedPayloadDigest.hs, whose explicit Text payload
parameter cannot satisfy rootedPayloadBindingKernel's PayloadDigest input. Its matching typed positive
changes only that parameter type. Add CoerceRootedPayloadDigest.hs and ForgeRootedPayloadDigest.hs for the
actual opaque constructor/coercion boundary, matching their measured type/constructor reasons rather than
hidden-module failures. The ordinary Main-only ImportHandoffRooted fixture remains unchanged and refuses.
Do not refer to the future ChildConfigDigest or its swap fixture until Sprint 13.44.

The value table refuses empty, 63-character, 65-character, uppercase and nonhex payload inputs. It accepts
canonical 64-character values and checks exact total elimination. The current genuine signed value identity
case uses the eliminator at its now-typed private getter, preserving exact public bytes, edge, computed SHA
and crypto verification. Existing public parsers retain every malformed transcript error and its precedence.

Replace only the scoped guard subjects explicitly owned above. Keep all five Handoff bundles, the request
reader, raw response119/6323/8017, capability78fee, two path-fold2c1d and Relay4292/5e88 subjects unchanged,
with every independent import/authority/producer/caller/ordering assertion. Actual source checks retain the
new constructor's abstraction and fixed validating producer; no new authority producer or testing seam exists.
Run focused HandoffSpec/public compile-fail/indexed project-plan foundation/DocValidatorSpec, then all four
host static commands. Record actual fixture reasons, production scope and outcomes before the next sprint.
The phase's separately declared gate remains owed at phase closure.

Dated 2026-11-02 pre-edit baseline: 35 texts, 910 Haskell hashes and 616 compiler fixtures. Rooted is
`55cede42469173f8a1523d5ee93ff3657342ae2317c46f84f8feb4e4b4504354` and Handoff is
`8bd0a27b528108c08939c237903b5cc03854c7019e680942757e6095a89efa38`.
The immutable preceding Rooted snapshot and this sprint's current bytes are identical. A Temp-only probe
compiled against all 100 actual selected-five Core-test compiler arguments unchanged, with existing
SourceGuard signature/plural-clause readers, ordered Aeson framing, compiled childConfigDigest and UTF-8.
Only Temp targets/output paths were appended. Compilation passed in 3.498506 seconds,
05:21:25.479636 to 05:21:28.978107 UTC; measurement passed in 0.932922 seconds,
05:21:41.092670 to 05:21:42.025575 UTC, both exit 0/empty stderr. All baseline/current entry arrays and
serialized bytes match; frozen source/package/project/plan/build-info/setup/binary hashes stayed exact.

The fixed positive preservation subjects, measured before any type edit, are:

| Owned subject | Actual entries/tokens | Ordered Aeson bytes | Fixed SHA-256 |
|---|---|---:|---|
| Closed request/response shapes plus independent payload nominal/nominal roles | 3 sections,149 tokens,811 token UTF-8 bytes | 1351 | `2f669c249c2291c98b4ce57e0b307479b2be669834e823d60b7683f22b19ae42` |
| Request codec, builders and fold | 31 declarations,568 signature/1019 clause tokens,10895 token UTF-8 bytes | 16871 | `5460d05bf207b1fe47943a2eed3cd7c54ebfdaee39e29fc143316ee4c43c70ae` |
| Response codec, pairing, builders and fold | 31 declarations,932 signature/2056 clause tokens,18442 token UTF-8 bytes | 28806 | `9110169cd7e92ea8ab12824c70c7a32715f9ed9d97c927ccd723e5edebacb426` |
| Shared digest/framing and fixed byte constants | 7 functions plus13 constants,98 signature/321 clause tokens,2292 token UTF-8 bytes | 4189 | `50411bdbff15a847d7550bd78b189104ca05fadd593467a7039e237889a2cf11` |

The exact positive declaration lists are retained in the measured probe/evidence. Function rows are ordered
(name, actual signature tokens, all actual complete clauses); shapes are actual source declaration tokens,
not a constructed expected value. decodeLifecycleVariant has eight complete clauses, decodeResponsePost and
require two each, and the other selected values one. Missing, ambiguous or empty subjects refuse. No module
header/export text, payload body, shared-file complement or line-count arithmetic enters these hashes.

Dated 2026-11-02 implementation/preflight evidence: exactly one new type changes two production owners,
41 nonempty/44 physical lines against the immutable baseline. Rooted changes 27/30 at
`fda21e3d37e9522d066f4b88cab3eec5b48963c605dc289afb5ab29417091733`; Handoff changes 14/14 at
`8d23f1e4555eb326b35016866a01f09c25c8380cac8f97c297c799339eaacc54`. Both signer declarations and
all five Handoff bundles remain raw-byte exact, as do all four positively measured Rooted subjects.
All other production files, Cabal9e675, project files and public Main exposure remain unchanged.
Independent production and documentation reviews pass; the doc changes 12 nonempty/14 physical lines.

Native Windows `C:\ghcup\bin\cabal.exe build all` from core passed in 24.849050 seconds,
05:36:14.946042 to 05:36:39.794939 UTC, exit 0/empty stderr, with frozen sources and metadata exact.
Production-only Linux sync passed in 2.207168 body/2.275372 outer seconds at 05:39:32.056169 to
05:39:34.263338 UTC. Linux core `cabal build all` passed in 32.325959 command seconds,
05:39:34.460532 to 05:40:06.8194152 UTC, exit 0, compiling actual owners/dependents and linking Main.
No tests or docs were copied into that production-only preflight snapshot.

Actual updated-library compiler probes used all 100 current selected-five arguments byte-for-byte and the
unchanged existing runHandoffCompiler Temp suffix. The matching typed positive passed exit 0/empty stderr
in 0.131155 seconds, 05:38:56.603672 to 05:38:56.734837 UTC; it differs only in payload parameter type.
RawTextAsRootedPayloadDigest failed for the actual kernel's second argument, expected Rooted.PayloadDigest
versus actual Text, GHC-83865, in 0.118132 seconds at 05:38:56.735579 to 05:38:56.853717 UTC.
CoerceRootedPayloadDigest failed with representation Text/Rooted.PayloadDigest and the constructor-not-in-scope
note, GHC-18872, in 0.115212 seconds at 05:38:56.854127 to 05:38:56.969343 UTC. ForgeRootedPayloadDigest
failed for illegal term-level use of the type constructor Rooted.PayloadDigest, GHC-01928, in 0.122347
seconds at 05:38:56.969741 to 05:38:57.092093 UTC. All three compiler exits are 1 for their named
reasons, with no hidden-module refusal. Source, argument and metadata hashes stayed exact. Append only
these three measured category mappings at the existing dispatcher; retain all old GHC-87110 and DATA
GHC-83865 mappings, resolver/runner/matcher behavior and Main-only privacy checks. These record production
preflights and compiler probes only; the test component and focused/full gates were still owed at that stage.

Dated 2026-11-02 test/component evidence: HandoffSpec changes 232 nonempty/241 physical lines at
`cb2b62ccd166b080a86c6b1f4a27784dc0bac8b5ea26445f229c033d837900a4`; CompileFailSpec changes 28/28.
The three new fixture subjects add 18 nonempty/24 physical lines, total test footprint 278/293. All 184
old Handoff labels remain, with two new cases, 186 total. The 179 unrelated old case bodies remain exact;
five old cases adopt only their declared typed-getter or scoped-guard subjects. Four premeasured bundle
hashes replace exactly the three whole-Rooted55cede occurrences and two 45ca self-comparison occurrences;
every other fixed hash, path literal and old ordered-check label remains exact. Explicit span rollback
restores both entire prior test files. All 616 old fixtures remain exact, with three new files, 619 total.
All 906 unrelated old Haskell files remain exact; there are now 913 Haskell files including those fixtures.

The initial native test build passed in 62.033744 seconds, 05:50:54.371845 to 05:51:56.405212 UTC,
exit 0/empty stderr, actual linked rts_thr. The first direct 12-case run failed only the Coerce fixture
registration in 8.17 reported/8.297519 wall seconds, 05:53:52.646667 to 05:54:00.944134 UTC, exit 1.
Its two expected phrases both matched the same actual GHC-18872 diagnostic block, while the existing matcher
requires distinct diagnostic blocks for separate phrases. The other eleven cases passed; the full focused
run was not started. Register one contiguous observed phrase retaining representation mismatch, arising
from coerce and the fully named constructor-not-in-scope note. No matcher, category, resolver, runner,
fixture or production change is needed. Independent review confirms the two-literal/list-only repair;
reversing it restores the initial d27ea32d compiler-spec freeze exactly.

The corrected CompileFailSpec is `7ed29453132b2d8b8edc094cc50830d3727ca4390b2bc890e4d8cae32fda538c`,
with the same 28/28 footprint. Corrected native component build passed in 8.345669 seconds,
05:57:15.122595 to 05:57:23.468213 UTC, exit 0/empty stderr, actual linked rts_thr; frozen sources
and metadata stayed exact. All twelve direct constructor, actual input/opacity compiler, genuine signed
value and scoped ownership/preservation cases passed in 9.64 reported/9.790091 wall seconds,
05:57:54.616981 to 05:58:04.407010 UTC, exit 0/empty stderr. These establish the checked scalar and
all four fixed preserved subjects without rebasing whole-file/count evidence. The full focused run and
four-command static gate were still owed at that stage.

The first full focused run failed two of 1047 tests in 196.59 reported/196.690548 wall seconds,
05:58:04.496885 to 06:01:21.186235 UTC, exit 1/empty stderr. Recovery's facade-size equality expected
101 but saw 102 because the declared typed validator lies inside that section. The fixture inventory also
rejected the three new qualified Rooted imports under its existing strict first-party grammar. Keep that
grammar/parser policy unchanged: use plain explicit first-party imports in only the three new subjects,
retain matching typed positive structure, and remeasure actual diagnostics before registering them. The
original 616 fixtures and public/module/privacy/matcher controls remain untouched. The initial full focused
run is not passing evidence.

The additional positively owned Recovery wrapper subject is exactly renderRecoveryChildPackage,
signRecoveryChildPackageBindingKernel and withVerifiedRecoveryChildPackage. Saved baseline Handoff8bd and
current Handoff8d have identical actual entry arrays and serialized bytes for those three declarations.
Its ordered Aeson size is 3275 bytes at fixed saved-baseline SHA-256
`a6baca281b530a958047e1eca25112d80a729058388b47d0674f9a145abd9451`.
Actual signature token counts are 5/31/23 (59 total), complete clause counts one each with 5/107/95 tokens
(207 total), and 2337 token UTF-8 bytes. The signer's signature field includes its six OPAQUE pragma tokens
alongside 25 type tokens; the existing plural-clause reader excludes that pragma and retains the complete
where body. This named wrapper subject excludes the changed private validator; it is no shared-file
complement. The other two config wrapper declarations already protected by the five-function bundle are
not silently added to this Recovery-owned subject.

The Temp-only actual-reader measurement compiled in 3.591102 seconds, 06:07:53.004807 to
06:07:56.595865 UTC, and ran in 0.215235 seconds, 06:07:56.596703 to 06:07:56.811922 UTC,
both exit 0/empty stderr. All 100 actual selected-five compiler arguments were unchanged, with only Temp
target/output paths appended; UTF-8, existing SourceGuard/Aeson and compiled childConfigDigest were used.
Saved/current wrapper bytes match and monitored source, configuration and binary hashes stayed exact.
Adopt this fixed subject before changing the expired size check, preserving Recovery78 and all other
facade controls. This extends the guard ownership declaration before its repair, without a production edit.

Plain-import repair evidence, 2026-11-02 UTC: only the three new fixtures use revised plain explicit
first-party imports; the matching typed positive has identical imports and differs only in payload type.
The RawText subject reexports its imported opaque PayloadDigest type solely to keep that identical import
used, adding no producer. The inventory grammar, matcher, resolver, argument runner and original 616
fixtures are unchanged. Re-probes used all 100 actual selected-five arguments unchanged. Positive source
`8158f6d7a2e104f25f241876e098454dc8cc9859664664f3023ef6d1688a0c0c` passed in 0.135303 seconds,
06:08:54.395814 to 06:08:54.531127 UTC, exit 0/empty stderr. Plain RawText failed for expected PayloadDigest
versus Text, GHC-83865, in 0.136537 seconds; Coerce failed for the Text/PayloadDigest representation and
fully named hidden-constructor note, GHC-18872, in 0.113684 seconds; Forge failed for illegal term-level
use of PayloadDigest, GHC-01928, in 0.108920 seconds. Those three compiler exits are 1; their runs span
06:08:54.532062 to 06:08:54.892044 UTC. Earlier decorated-subject probe results remain intermediate
evidence; the plain canonical subjects and their actual named diagnostics close this fixture obligation.

Final HandoffSpec is `f36444ee7ca06775831576a75d41c3504990ce952c6e0c3a6b4c0207f927264a`,
241 nonempty/250 physical lines; CompileFailSpec is
`19bcbdea006142249c8d5455e5f2dcc1509b4613ff8784a69ede372ce5d1bdd9`, 28/28. The three new fixtures
are 430/191/169 bytes and add 18/24 lines, giving a final test footprint of 287 nonempty/302 physical.
All 184 old labels remain plus two new cases; 178 old case bodies are exact and six adopt only their
declared typed/scoped subjects. Restoring only the retired facade101 equality reverses the recovery guard
repair to cb2b62cc exactly. Recovery78 and every other facade control remain; all other source/crypto/path/
caller/producer controls and old fixture bytes are retained. Independent final reciprocal review passes.

The corrected plain-subject native component build passed in 30.738043 seconds,
06:18:10.123591 to 06:18:40.861419 UTC, exit 0/empty stderr, actual linked rts_thr, with frozen source
and metadata exact. The two formerly failing checks and twelve scalar/compiler/preservation checks passed
14/14 in 10.46 reported/10.634004 wall seconds, 06:21:58.711078 to 06:22:09.345017 UTC,
exit 0/empty stderr. The full focused rerun and four-command gate were still owed at that stage; no full gate was launched
from either earlier failing direct/focused result.

Dated 2026-11-02 final validation: the corrected native focused selection passed all 1047 cases in
171.79 reported/171.892487 wall seconds, 06:22:09.430255 to 06:25:01.321656 UTC, exit 0/empty
stderr. The actual frozen source/metadata hashes matched after the run. Earlier failing direct/focused
artifacts did not authorize a Linux gate.

The final Linux x86_64 host static gate ran once, unfiltered, on the reviewed frozen snapshot with
GHC 9.12.4, Cabal 3.16.1.0 and default `-Werror`. The Cabal reporting options below select no tests.

| Command and root | Explicit result | Reported test seconds | Command seconds | UTC start to finish | Parent exit |
|---|---|---:|---:|---|---:|
| `cabal test all --test-show-details=direct --test-options=--hide-successes`, core | All 3886; Cabal PASS | 247.67 | 310.9263094 | 06:28:35.8613605 to 06:33:46.8227115 | 0 |
| Same unfiltered Cabal command, demo | All 165 demo plus All 3886 included core; Cabal PASS | 1.38 plus 249.71 | 332.4623581 | 06:28:35.8714304 to 06:34:08.3662804 | 0 |
| `poetry run python -m hostbootstrap.check_code`, repository root | Ruff, Black and Mypy passed | N/A | 0.7602338 | 06:28:35.8850970 to 06:28:36.6815994 | 0 |
| `poetry run python -m hostbootstrap.test_all`, repository root | All 376; 100% statement and branch coverage | 5.78 | 6.7359030 | 06:28:35.8871672 to 06:28:42.6588273 | 0 |

Both core runs recorded 26 conditional families, 62 supported completions and 21 refusals, including
the actual filesystem-root row `(1,0)`. The provider-live wrapper passed its default not-requested row;
this static run makes no physical-provider or recursive-process acceptance claim.

Final read-only source/fixture/metadata/document consistency passed at 06:34:56.491194 to
06:35:08.256531 UTC, 11.765336 body/16.508219 outer seconds, parent 0. All 913 Haskell files match
the snapshot at aggregate `7d3cc972f9f4c38f652ab84537c26a9960abfe805b39d1656ab9c89835e249db`;
the 888 files under core source/internal/test aggregate to
`ef15c7d194b89c0bc3e0cf749e07814f88016d25df7f4b47cc4471ae14a34c03`.
Exactly the two production and two existing test owners changed, with three new plain-import fixtures;
906 original Haskell files, all 616 old fixture bytes, 55 other relocated bodies and all 57 absent old
homes remain exact. Current fixture inventory is 619. Current recorded test spans restore both complete
immutable test baselines. Only the declared whole/count pins retire; the four Rooted and named Recovery
wrapper subjects, all other hash occurrences, five Handoff bundles, capability/path/response/Relay
subjects, 109 path arrays, original ordered-check labels and current Cabal/project/public inventories
retain their declared boundaries. All 95 held governed documents match the snapshot.

The actual compiled ownership digest over the Phase 1 covered paths remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`: query exit 0 in
0.183786 seconds, 0.488109 outer seconds at 06:34:56.381472 to 06:34:56.903891 UTC. Phase 1
remains Done with its single current evidence field. Final process/additional-metadata audit passed
at 06:35:43.453186 to 06:35:43.793945 UTC in 0.340764 seconds, parent 0. The retained container
keeps its original 2026-10-30 StartedAt, init and both writable source/cache mounts; only init, sleep
and the audit process remained, with no surviving test/probe children. Git history was untouched.

Intermediate audit/setup attempts are separate from that passing gate: the first external rollback
helper exited 1 at 06:02:51.835092 to 06:03:05.714603 UTC, 13.879610 seconds, because it reversed
the earlier Coerce repair before applying already updated final rollback spans. The helper alone was
corrected to apply current spans directly. A retry never entered Linux: WSL_E_DISTRO_NOT_FOUND at
06:04:52.046424 to 06:04:53.652137 UTC, 1.605725 seconds, underlying exit 4294967295/wrapper 1.
Read-only inspection confirmed the exact existing distro/container running with retained mounts; no
restart or storage change occurred. The successful final sync/audit then passed at 06:26:50.890067 to
06:27:05.275638 UTC, 14.385570 body/19.192247 outer seconds, parent 0, before gate launch.
Neither setup attempt is a test result; no Linux full gate was launched from an earlier failed focus.

Native closed-status documentation validation passed all 17 DocValidatorSpec cases in 6.74 reported/
6.829920 wall seconds, 2026-11-02 06:43:08.166184 to 06:43:14.996080 UTC, exit 0/empty stderr.
The actual core-test binary ran from core/hostbootstrap-core with C:\ghcup\bin prepended to PATH;
its explicit completion and frozen source/metadata equality are retained in the external closure capture.
Sprint 43 is Done with no remaining work; Sprint 44 owns planning, and the phase itself remains Active.

#### Remaining Work

None.

### Sprint 13.44: Child config digest has its own checked role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across Rooted and Handoff; exactly one new named type
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give the existing kernel input role ChildConfigDigest its own checked opaque scalar, accepting 64 lowercase hexadecimal characters.
This is one input-contract adoption. The five post-open request builders, nonce-only OpenFrame, Opened response
and broader descriptive fold-return adoption belong to Sprint 17.73's separately bounded caller work.

#### Deliverables

- Add only the abstract `ChildConfigDigest`, hidden constructor, `mkChildConfigDigest` and total
  `childConfigDigestText` in Rooted. The factory applies the existing `requireDigest "child config"`
  predicate. This is inert DATA; no authority, parameter-role annotation or raw accepting adapter is added.
- Retain `PayloadDigest` unchanged. Type the child-config field/getter, both real payload-kernel inputs
  and the existing private unsigned renderer with `ChildConfigDigest`; encode only through its total
  eliminator. Decode the existing payload field and smart-wrap it first, then decode and smart-wrap the
  child-config field, retaining existing refusal precedence, framing, bounds and admitted wire bytes.
- Adopt only the two existing Handoff validator tuples and `rootedUnsigned` child argument. Each validator
  smart-wraps its actual computed config digest after all existing broker/kind/byte/edge/conflation checks
  and the existing payload smart-wrap. The public config projection remains Text through the eliminator.
  Both signer clauses and all five named Handoff preservation bundles remain byte-identical.
- Preserve the four positively named Rooted subjects measured in Sprint 13.43 and the three named Recovery
  wrapper declarations, including every actual plural clause. Their fixed hashes, neutral Recovery78,
  capability/path/raw-response/Relay controls, all other production modules, Cabal/project files, private
  graph, public inventory and Main-only privacy remain exact. No whole-file or count digest is rebased.
- Add the child scalar's malformed/valid-value table and exact elimination checks; adopt the existing
  genuinely signed identity case's private child getter through its eliminator. Adopt only the child-role
  export/type/input/renderer/decoder/caller source controls while retaining independent checks and old labels.
- Add `SwapRootedPayloadDigests.hs`, `CoerceRootedChildConfigDigest.hs` and
  `ForgeRootedChildConfigDigest.hs` with plain explicit imports in the actual selected-five context.
  The swap uses both actual opaque roles at the real kernel; its matching positive changes only the
  two callee arguments. Coercion and constructor-forgery fixtures explicitly request
  `ChildConfigDigest(..)` through the existing import grammar, so a leaked constructor is visible to
  each subject. Measure actual diagnostic categories and one complete phrase per diagnostic.
  All 619 existing fixture bytes remain exact. Remeasure `RawTextAsRootedPayloadDigest.hs` and retain
  its original payload-specific mismatch even if the new child slot yields another diagnostic. Its
  existing inline positive explicitly adopts the ChildConfigDigest import and typed child parameter;
  Sprint 13.43's measured single-parameter difference remains dated evidence for that earlier contract.
- Update only the declared architecture document for the actual second inert scalar and its current
  input/caller boundary. Other scalar roles and broader descriptive fold-return adoption keep their own scopes.

#### Validation

HandoffSpec retains the genuinely signed payload identity, fixed request/response/framing/role declarations,
neutral Recovery wrappers, exact wire goldens, round trips, refusal ordering and producer/caller controls.
The new child-config table refuses empty, 63/65-character, uppercase and nonhex Text and eliminates valid
64-character values exactly. CompileFailSpec uses the actual selected-five compiler arguments, measured
role-specific swap/coerce/forge diagnostics and matching typed positives; its resolver, runner, matcher,
strict fixture-import grammar and existing Main-only private-import controls remain unchanged.
Run the actual focused HandoffSpec/public compile-fail/indexed project-plan foundation/DocValidatorSpec
selection, then all four host static commands from their declared roots. Record measured production scope,
constructor boundaries and actual results. The phase's separate gate remains due at phase closure.

Dated 2026-11-02 pre-edit baseline, 06:44:18.135225 UTC: 35 text snapshots, 913 Haskell files and
619 canonical fixtures are captured outside the repository. Rooted is
`fda21e3d37e9522d066f4b88cab3eec5b48963c605dc289afb5ab29417091733`; Handoff is
`8d23f1e4555eb326b35016866a01f09c25c8380cac8f97c297c799339eaacc54`.
Fresh native measurements apply the unchanged actual 100 selected-five compiler arguments and actual
SourceGuard readers to saved baseline/current declarations. Rooted helper build passed in 3.477817 seconds
at 06:45:01.177015 to 06:45:04.654828 UTC; measurement passed in 1.012083 seconds at
06:45:04.654843 to 06:45:05.666927 UTC. The four ordered Aeson subjects retain respectively
1351/16871/28806/4189 bytes and fixed digests
`2f669c249c2291c98b4ce57e0b307479b2be669834e823d60b7683f22b19ae42`,
`5460d05bf207b1fe47943a2eed3cd7c54ebfdaee39e29fc143316ee4c43c70ae`,
`9110169cd7e92ea8ab12824c70c7a32715f9ed9d97c927ccd723e5edebacb426`, and
`50411bdbff15a847d7550bd78b189104ca05fadd593467a7039e237889a2cf11`.
Recovery helper build passed in 3.433094 seconds at 06:45:05.668106 to 06:45:09.101191 UTC;
measurement passed in 0.190587 seconds at 06:45:09.101206 to 06:45:09.291797 UTC. Its named
render/sign/verify tuple stays 3275 Aeson bytes at
`a6baca281b530a958047e1eca25112d80a729058388b47d0674f9a145abd9451`.
All four processes exited 0 with empty stderr; actual declaration entries/serialized bytes and frozen
source/metadata match. These are preservation measurements; implementation and its gates remain owed.

Dated 2026-11-02 production implementation: exactly one new ChildConfigDigest, 41 changed nonempty
lines / 44 physical lines across only Rooted (27/30) and Handoff (14/14). Frozen source hashes are
`d7cf396783daf83949d45c1a558ddd66f6bc9e9c2345ac09488163688cc6c485` and
`19bebaea8c5e22776df118cbd3e4785ded8b66966645ad15bd05d72e397d4fd0` respectively.
Both signer clauses, all five Handoff bundles, the four Rooted subjects and three Recovery wrappers
remain raw-identical. The PayloadDigest declaration/factory/eliminator, 202 other production files,
Cabal/project bytes and all 619 existing fixtures remain exact. Full production-span reversals recover
both immutable baseline files. Independent declared-document review passes; its actual second inert
scalar boundary has no broader lifecycle or authority claim.

Native `cabal build all` from core passed at 06:50:45.248611 to 06:51:04.412308 UTC,
19.163816 seconds, exit 0/empty stderr, with all production and Cabal/project hashes exact. A preceding
wrapper attempt failed before Cabal executed because Windows CreateProcess could not resolve a bare
cabal name through the child-only PATH; the runner uses the actual absolute Cabal executable. That setup
exception is separate from the passing build and provides no test evidence.

The actual selected-five test compiler's 100 arguments remain byte-identical to the measured context.
Six compiler probes passed their declared outcomes at 06:52:06.366488 to 06:52:07.105870 UTC:

| Actual source | Exit | Seconds | Observed diagnostic |
|---|---:|---:|---|
| Adopted payload typed positive | 0 | 0.130098 | Empty stderr |
| Matching payload/child swap positive | 0 | 0.127063 | Empty stderr |
| SwapRootedPayloadDigests.hs | 1 | 0.129318 | Two GHC-83865 blocks, expected PayloadDigest/actual ChildConfigDigest and the reverse |
| CoerceRootedChildConfigDigest.hs | 1 | 0.115100 | One GHC-18872 block, Text/ChildConfigDigest representation mismatch with hidden-constructor note |
| ForgeRootedChildConfigDigest.hs | 1 | 0.106803 | GHC-01928, illegal term-level use of ChildConfigDigest |
| Immutable RawTextAsRootedPayloadDigest.hs | 1 | 0.128432 | Original payload-specific GHC-83865 phrase remains exact; separate child/Text mismatch also present |

Both positives are the exact current inline literals. Their SHA-256 values are
`2f19363abbff3bce7f6bb1e30f763bf379576643fa374044dce70a2580821468` (471 bytes) and
`747e2ad0975086450e2f46a1f6c48df6077dcf89d20d46f63be88aaa898e9792` (449 bytes).
The swap positive differs from its negative only in the two callee arguments. All actual probe source,
production and compiler metadata hashes remain frozen. Full focused and four-command gates remain owed.

Dated 2026-11-02 initial final-test validation: 87 changed nonempty / 93 physical test lines across
HandoffSpec (39/39), CompileFailSpec (30/30), and three new fixtures (18/24). HandoffSpec is
`41a6f86d2d24936cf1600ce88b738774a9107e36628b6742c48af9759e98d097`; CompileFailSpec is
`76fba61a302d407fe43a581f520cf6e6b7f4b50a8c2137810eb43b5d80310c68`.
All 186 old Handoff labels remain, with one new value-table case; only the two declared old cases
adopt the child role. All 18 old hash occurrences, old physical paths/ordered labels, 619 old fixtures,
909 unrelated Haskell files and preservation helpers remain exact. Both recorded full-span test
reversals restore their immutable baselines. Reciprocal review passes. One external audit extraction
initially chose an end marker before diagnosticMatcherCases; correcting only that extraction to stop
before data HandoffTestCompiler established the actual unchanged matcher/runner/grammar suffix.
No repository source changed for that audit-helper correction.

The native test component build passed at 06:56:20.973691 to 06:57:12.523664 UTC in
51.550298 seconds, exit 0/empty stderr, actual linked rts_thr, with frozen source/metadata exact.
The 19 direct boundary/preservation cases passed in 11.22 reported / 11.376590 wall seconds at
07:02:04.960549 to 07:02:16.337087 UTC; the full focused 1052-case selection passed in
183.54 reported / 183.651553 wall seconds at 07:02:16.555232 to 07:05:20.205681 UTC.
Both exited 0 with empty stderr and unchanged source/compiler snapshots. Their original two new
constructor fixtures used bare ChildConfigDigest imports; the owner-export improvement below requires
fresh validation of its final fixture bytes before the Linux gate.

Dated 2026-11-02 constructor-boundary measurement, before either canonical fixture is changed:
actual selected-five 100 arguments compile Temp copies with `ChildConfigDigest(..)` imports.
Coercion refuses with the same single complete GHC-18872 representation/hidden-constructor diagnostic
in 0.120848 seconds, 12:42:21.525354 to 12:42:21.646217 UTC, exit 1. Constructor forgery
refuses with the same GHC-01928 term-level type-constructor diagnostic in 0.121902 seconds,
12:42:21.647192 to 12:42:21.769104 UTC, exit 1. Neither output adds an import warning/error.
The measured source hashes are respectively
`a8945905524a86c1106ce1104ba35a599cd2410cdbf5371ab5153f8c436a206f` and
`e09253ff4045bb6e5f0970c589968c5f658c8fc5770966e134fef3c68b1dc09a`.
Two alternative whole-module-import probes also reached the named errors, but the canonical subjects
use the narrower explicit constructor-requesting form declared above. Existing source, compiler metadata
and all old fixture bytes stayed frozen throughout these measurements. The two new fixtures alone
adopt the measured import; production, test modules, registrations, diagnostics and old619 remain exact.

The two final canonical constructor-requesting fixture files match those exact measured hashes.
Their actual-path selected-five probes passed the named refusals at 12:44:22.253847 to
12:44:22.478811 UTC: Coerce exit 1/GHC-18872 in 0.115962 seconds; Forge exit 1/GHC-01928 in
0.108253 seconds. All complete expected phrases remain unchanged, with no import warning/error;
production, test modules, compiler metadata, Swap, positives and all 619 old fixtures remain exact.
Only these two runtime-loaded fixture import lines changed after the earlier passing focus; the current
19-case direct selection and full 1052-case focused rerun are due before the full static gate.

Dated 2026-11-02 final validation of the strengthened canonical fixtures: the 19 direct cases passed
in 11.43 reported / 11.578602 wall seconds at 12:44:39.633943 to 12:44:51.212489 UTC.
The full focused 1052-case selection passed in 183.22 reported / 183.322724 wall seconds at
12:44:51.420739 to 12:47:54.742324 UTC. Both parent exits were 0 with empty stderr and exact
source/compiler snapshots. Only runtime-loaded fixture imports changed since the preceding component
build; both test-module bytes and the actual linked threaded binary remained unchanged.

The reviewed frozen snapshot passed exactly one unfiltered Linux x86_64 host static gate, with
GHC 9.12.4, Cabal 3.16.1.0 and default -Werror. Reporting options select no tests.

| Command and root | Explicit result | Reported test seconds | Command seconds | Parent exit |
|---|---|---:|---:|---:|
| `cabal test all --test-show-details=direct --test-options=--hide-successes`, core | All 3891; Cabal PASS | 303.88 | 403.3883780 | 0 |
| Same unfiltered Cabal command, demo | All 165 demo plus All 3891 included core; Cabal PASS | 1.69 plus 304.26 | 398.7530168 | 0 |
| `poetry run python -m hostbootstrap.check_code`, repository root | Ruff, Black and Mypy passed | N/A | 1.4371642 | 0 |
| `poetry run python -m hostbootstrap.test_all`, repository root | All 376; 100% statement and branch coverage | 6.22 | 7.4866407 | 0 |

The core command ran 12:54:24.452835 to 13:01:07.880102 UTC; demo ran 12:54:24.474352 to
13:01:03.271393 UTC. Both core outputs measured 26 conditional families, 62 supported rows and 21
refusals, including the actual root case `(1,0)`. Provider-live default not-requested wrappers passed.
Python coverage measured 1585 statements and 460 branches with zero misses or partial branches.
This static gate makes no physical-provider or recursive-process acceptance claim.

Final read-only source/fixture/document/metadata audit passed at 13:01:29.173817 to 13:01:41.319723
UTC, 12.145904 body / 16.916944 outer seconds, parent 0. All 916 Haskell files match the held snapshot
at `96dcba6d6025df61680b487c08d3c22117d374539ff7087176ae4e61ed1918c8`; the 891 core
source/internal/test files aggregate to
`9bd5325c99d532fbe5a632b7271d657316514c34b407511523fdf6984344e672`. All 95 held governed
documents match `661fb6c9f635ade3b47174400f0b657c01ed8a50df5d9988c5821413db4535d1`.
Exactly two production and two existing test owners changed, with three new canonical fixtures;
909 original Haskell files and all 619 old fixture bytes remain exact, with 622 current fixtures.
Recorded reversals restore both complete test baselines; 55 other relocated bodies and all 57 absent
old homes remain exact. All fixed Rooted/Recovery/Handoff/capability/path/raw-response/Relay subjects,
Cabal/project bytes, private/public inventories and other ordered controls match their declared scope.

The canonical compiled Phase 1 covered-path digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`: query 0.185059 seconds,
wrapper 0.499927 seconds/exit 0 at 13:01:29.044056 to 13:01:29.581008 UTC. Phase 1 stays Done;
its covered Python paths are unchanged. Final process/additional-metadata audit passed at
13:01:45.901253 to 13:01:46.266527 UTC, 0.365280 seconds, parent 0. The retained container keeps
its original StartedAt, init and both writable source/cache mounts; only init, sleep and audit ps remain,
with no surviving test/probe children. Git history remains untouched.

The external audit helper's first attempt exited 1 at 12:50:40.765163 to 12:50:54.385045 UTC,
13.619971 seconds, because its newly written expected label omitted the word config from the actual
frozen private child config scalar label. Correcting that external assertion alone produced a passing
sync/audit at 12:52:17.596792 to 12:52:33.198306 UTC, 15.601512 body / 21.092044 outer seconds,
parent 0, before gate launch. No repository source changed for that correction, and no full gate was
launched from the failing helper. The earlier and final native focused runs both passed; only the final
constructor-requesting fixture bytes authorize this full gate.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T13:04:02.581069+00:00 to 2026-11-02T13:04:09.119908+00:00,
6.538863 wall seconds, exit 0/empty stderr, with the closed status and all frozen test/Cabal bytes
unchanged throughout. The scoped plan/README diff check also passes.

#### Remaining Work

None.


### Sprint 13.45: Response request digest has its own checked role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across Rooted and Relay; exactly one new named type
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give the existing kernel input role RequestDigest its own checked opaque scalar, accepting 64 lowercase hexadecimal characters.
This is one input-contract adoption. The five post-open request builders, nonce-only OpenFrame, Opened response
and broader descriptive fold-return adoption belong to Sprint 17.73's separately bounded caller work.

#### Deliverables

- Add only abstract `RequestDigest`, its hidden constructor, `mkRequestDigest` and total
  `requestDigestText` in Rooted. The factory applies the existing `requireDigest "rooted lifecycle request"`
  predicate. It is monomorphic inert DATA with no parameter-role annotation or authority/raw accepting API.
- Type the existing Prepared, Descend, Settled, FrameComplete, ReceiptRecorded and Refused unsigned response
  inputs and private `opaqueResponseUnsigned` request slot. The already raw-validated digest is smart-wrapped
  at existing canonical reconstruction calls in `decodeUnsignedResponse` and `decodeOpaqueResponse`.
  These nine existing response declarations are the owned input-adoption set. Opened, raw common validators,
  callback/fold outputs, response DATA shapes and request/response pairing remain Text contracts.
- Adopt only Relay's `withRootedPreparedResponseKernel` and `withRootedPostOpenResponseKernel` callers.
  Each wraps the digest computed from the exact existing rendered request bytes inside the existing Either
  passed to signAndUse, after its attached-session and post-open checks; Prepared also retains its grant fold.
  Preserve responseFailure mapping,
  callback timing and all IO ordering. Other opaque body bytes retain their existing contracts.
- Preserve the three existing Rooted shape/role, request31 and shared/framing subjects. The response subject
  is the positively named 22-declaration framing/description set measured below; only the expired live
  31-declaration response hash becomes dated Sprint 13.43/13.44 evidence. No hash or global count is rebased.
  Keep every other fixed Recovery/Handoff/capability/path/raw-response subject, Relay's 4292-byte transport
  sections, all other production modules, Cabal/project bytes, public/private inventories and old labels exact.
- Adopt only the owned Rooted/Relay input/export/canonical-reconstruction source controls and the response
  helper's explicit 22-name list/fixed expected digest. Keep generic readers/matchers unchanged. Add one
  malformed/valid constructor/eliminator table and one actual six-builder canonical-byte table against the
  existing independent rootedLifecyclePostUnsigned renderer; retain wire goldens, round trips, DATA/crypto
  families, exact refusal order and request-pairing controls.
- Add `RawTextAsRootedRequestDigest.hs`, `PayloadDigestAsRootedRequestDigest.hs`,
  `CoerceRootedRequestDigest.hs` and `ForgeRootedRequestDigest.hs`. The first two mistype only the actual
  Descend response kernel's request slot; matching inline positives change only that parameter to RequestDigest.
  Keep otherwise-unused abstract imports used through module reexports where required by -Werror.
  Constructor negatives explicitly request `RequestDigest(..)` with the existing plain import grammar.
  Measure actual selected-five compiler categories and complete per-diagnostic phrases before registration.
  All 622 old fixtures and existing typed positives stay byte-identical; no fictitious two-slot swap is added.
- Update only the declared architecture document for the actual third inert scalar and six input boundaries.
  Nonce-only OpenFrame, Opened and broader descriptive fold-return adoption keep their own declared scope.

#### Validation

HandoffSpec exercises malformed Text (empty, 63/65-character, uppercase and nonhex), valid64 exact elimination,
the six actual typed response builders' unchanged bytes, existing wire/crypto/refusal-order/request-pairing
controls and the fixed positively named preservation subjects. CompileFailSpec applies the real selected-five
context to raw Text, the existing wrong PayloadDigest role, constructor forgery and coercion at the declared
boundaries, with matching typed positives. Main-only privacy, resolver/runner, complete diagnostic matcher and
strict import grammar remain unchanged. Run the actual focused HandoffSpec/public compile-fail/indexed
project-plan foundation/DocValidatorSpec selection, then all four host static commands; record actual scope,
constructor boundaries and results. The phase's separate gate remains due at phase closure.

Dated 2026-11-02 pre-edit baseline at 13:04:32.992555 UTC captures 35 texts, 916 Haskell files and
622 canonical fixtures outside the repository. Rooted is
`d7cf396783daf83949d45c1a558ddd66f6bc9e9c2345ac09488163688cc6c485`; Relay is
`09f8c1363ddb60f31ed34c52b44a4e79729b29e9efd3c79ff31df174a578159d`.
Before any source/test edit, the actual 100 selected-five compiler arguments build a Temp measurement helper
using current SourceGuard signature/plural-clause readers and compiled childConfigDigest/Aeson serialization.
The helper build passed at 13:05:36.585291 to 13:05:40.843305 UTC in 4.258021 seconds; baseline/current
measurement passed at 13:05:40.843320 to 13:05:41.781459 UTC in 0.938137 seconds. Both exited 0 with
empty stderr and all frozen source/metadata exact; actual entries and serialized bytes compare equal.

The positive response framing/description subject lists these actual declarations, in this order:
`rootedOpenedResponseUnsignedKernel`, `requireResponseCommon`, `requireResponsePostOpen`,
`requireResponseBody`, `preparedResponseBody`, `responseCommon`, `responseWire`, `responsePostOpenWire`,
`boundedResponseUnsigned`, `rootedLifecycleResponseFromUnsignedKernel`, `rootedLifecycleResponseFromWireKernel`,
`withUnsignedResponse`, `decodeResponseCommon`, `decodeResponsePost`, `decodeResponseDigest`,
`decodePreparedResponseBody`, `rootedLifecycleResponseSignatureKernel`, `renderRootedLifecycleResponseKernel`,
`renderRootedLifecycleUnsignedResponseKernel`, `rootedLifecycleResponsePairKernel`,
`rootedLifecycleUnsignedResponsePairKernel`, and `withRootedLifecycleResponseKernel`.
Actual ordered (name, signature tokens, complete clause-token lists) serialization is 20240 Aeson bytes,
569 signature tokens, 1534 clause tokens and 12967 token UTF-8 bytes, at fixed SHA-256
`48fbcb826f5bae7f727276a3950e05679bda7fd9892250e00dd634e1cbdd9b6f`.
Actual decodeResponsePost has two clauses; each other listed value has one. This is an independently named
source subject, not a whole-file/header/complement or fabricated count. The other measured subjects retain
1351/16871/4189 bytes and their existing shape/request/shared digests. Recovery a6 and all other independent
preservation controls remain due unchanged. Implementation and its gates are still owed.

Dated 2026-11-02 production freeze: exactly one RequestDigest, 83 changed nonempty / 86 physical lines
across Rooted (52/55) and Relay (31/31). Frozen source hashes are
`c3cd9d295ba555c3b502224b308a5d58d29a5b8f02adc6c1faee007852a5583a` and
`316928821f3ea1f5c4d5f6e5f3a76499cea157d341c3d2f456144edae6f751ef` respectively.
The exact caller map remains the two declared Relay functions; Prepared retains its grant fold while
both callers retain their attached-session/post-open checks. Independent initial production review passes.
The new documentation paragraph preserves every pre-sprint byte and makes that distinction explicit.

Native `cabal build all` from core passed at 13:13:39.476051 to 13:13:57.063537 UTC in
17.587590 seconds, parent 0/empty stderr. All production and Cabal/project hashes remain exact.
The current selected-five compiler arguments remain the same actual 100 arguments. Six source probes
passed their declared outcomes at 13:14:57.435518 to 13:14:58.370216 UTC:

| Actual source | Exit | Seconds | Named result |
|---|---:|---:|---|
| RequestDigest typed positive | 0 | 0.164886 | Empty stderr |
| Distinct-from-PayloadDigest typed positive | 0 | 0.162320 | Empty stderr |
| RawTextAsRootedRequestDigest.hs | 1 | 0.161687 | GHC-83865, expected RequestDigest / actual Text at real Descend request input |
| PayloadDigestAsRootedRequestDigest.hs | 1 | 0.167222 | GHC-83865, expected RequestDigest / actual PayloadDigest at that input |
| CoerceRootedRequestDigest.hs | 1 | 0.142599 | One GHC-18872 representation block with the complete hidden-constructor note |
| ForgeRootedRequestDigest.hs | 1 | 0.133542 | GHC-01928, illegal term-level use of RequestDigest |

Each negative has one diagnostic block and one complete registered phrase. Constructor subjects request
RequestDigest(..) and reach the declared abstraction errors without import warnings/errors. Both positive
sources are exact current inline literals and differ from their own negatives only in the first parameter
type. Actual probe source/compiler metadata hashes stay exact. Their measured source SHA-256 values are:

- RootedRequestDigestTypedInput: `4acd9b3a0118c81bf121e4213566e87b5dbffa617a10902175a5419c9ab28031`.
- RootedRequestDigestDistinctPayloadInput: `9c6eae8d74219369d2cc7f0ad89fbce503e1ca4074c0f93768c16e18dd2a2d27`.
- RawTextAsRootedRequestDigest.hs: `720808ab7ac73c6d22a642d2812773c2d3387711d298a904fad272e5dbb736a9`.
- PayloadDigestAsRootedRequestDigest.hs: `3822b26c2e34b8808969a20f4c97a00366c8f205278abba6be260000da6dd4d9`.
- CoerceRootedRequestDigest.hs: `c67aef534729b8410dc5454d78626ff8f39d051334568935b579b31cdffaf414`.
- ForgeRootedRequestDigest.hs: `e39df7d785ffa757d3bc943a3e733e75ce2ee2ace33651a9620f5a0166ed8d4c`.

Native test compilation, focused validation and all four static commands remain owed at this point.

The first native test-component build exited 1 at 13:16:15.373449 to 13:16:21.859624 UTC,
6.486213 seconds: GHC-88464 identified the new canonical-byte case's missing assertEqual import.
No direct or full focused execution started. The existing explicit Test.Tasty.HUnit import alone adds
that used name; HandoffSpec is re-frozen at
`117ebfc21e5a732ed9aa3e055dd5d01b2865e69b514b29d3b5273998b1262b25`.
CompileFailSpec remains `e7b6b91c2d2e47137a4e1904262d96c45fb3668f7b168bc552aa4e76aab1566e`;
production, all old fixtures, new measured fixtures and positive literals remain exact. The actual
updated component build and declared focused/full gates remain due.

The corrected native test-component build passed at 13:17:48.590818 to 13:18:18.366354 UTC,
29.775716 seconds, parent 0/empty stderr, with actual linked rts_thr and all frozen source/metadata exact.
Only the already recorded Tasty import repair separates it from the first test build. Focused execution
and the four-command static gate remain due; no tests were counted from the failed compilation.

Dated 2026-11-02 final test scope: 234 changed nonempty / 242 physical lines across HandoffSpec
(169/169), CompileFailSpec (40/40) and four new fixtures (25/33). The corrected test hashes remain
`117ebfc21e5a732ed9aa3e055dd5d01b2865e69b514b29d3b5273998b1262b25` and
`e7b6b91c2d2e47137a4e1904262d96c45fb3668f7b168bc552aa4e76aab1566e`.
All 187 old labels remain with two new cases; only the declared 31-to-22 response subject changes among
18 prior hash occurrences. Both exact full-span test reversals restore baseline files. All 622 old fixture
bytes, 912 unrelated Haskell files, old positives, generic readers/matchers/resolvers/import grammar and
independent preservation subjects remain exact. Reciprocal test and documentation reviews pass.

The 27-case native direct selection passed at 13:19:46.440264 to 13:19:59.630689 UTC in
13.00 reported / 13.190487 wall seconds. Full focused validation passed all 1060 cases at
13:19:59.853463 to 13:22:55.379554 UTC in 175.39 reported / 175.527145 wall seconds.
Both parent exits were 0 with empty stderr and exact frozen source/compiler metadata.

The reviewed frozen snapshot passed exactly one unfiltered Linux x86_64 host static gate with
GHC 9.12.4, Cabal 3.16.1.0 and default -Werror. Reporting flags select no tests.

| Command and root | Explicit result | Reported test seconds | Command seconds | Parent exit |
|---|---|---:|---:|---:|
| `cabal test all --test-show-details=direct --test-options=--hide-successes`, core | All 3899; Cabal PASS | 265.32 | 324.3791181 | 0 |
| Same unfiltered Cabal command, demo | All 165 demo plus All 3899 included core; Cabal PASS | 1.42 plus 264.05 | 319.7095996 | 0 |
| `poetry run python -m hostbootstrap.check_code`, repository root | Ruff, Black and Mypy passed | N/A | 0.7694822 | 0 |
| `poetry run python -m hostbootstrap.test_all`, repository root | All 376; 100% statement and branch coverage | 5.85 | 7.1309865 | 0 |

Core ran 13:32:09.839582 to 13:37:34.216738 UTC; demo ran 13:32:09.839093 to
13:37:29.546760 UTC. Checks ran 13:32:09.838566 to 13:32:10.608061 UTC; Python tests ran
13:32:09.849718 to 13:32:16.980678 UTC. Both core outputs explicitly recorded 26 conditional
families, 62 supported rows and 21 refusals, including the real root case `(1,0)`. Python measured
1585 statements and 460 branches with zero misses or partial branches. Provider-live default
not-requested wrappers passed; these static runs make no physical-provider acceptance claim.

The root's synchronization copied and verified only the 11 changed files at 13:29:51.103564 to
13:29:51.206925 UTC, 0.103346 seconds/exit 0. Before the gate, an actual Linux/native comparison
of 1045 source/Python/document/metadata files and the exact 920-Haskell-file directory set passed at
13:31:29.193795 to 13:31:29.511046 UTC, 0.317235 seconds/exit 0. The independent read-only
preservation audit passed at 13:32:07.061532 to 13:32:19.721082 UTC, 12.659548 body /
17.705731 outer seconds, parent 0. The actual byte comparison above establishes the current
snapshot before gate launch; no gate ran against the earlier snapshot.

Final post-gate source/fixture/document/metadata audit passed at 13:38:51.000456 to
13:39:02.713121 UTC, 11.712663 body / 16.468904 outer seconds, parent 0. All 920 Haskell files
match `9e1e10755567a284c6d6cde16bd71838512b970f3ff28df5861de60f54ac85c7`; the 895 core
source/internal/test files match
`e7e28f91d0206b87e51aa22286af9aded756abe6cf92003faabd15894c7b2666`; the 95 held governed
documents match `0e17f48c8e044bd5f0a85838750a022a22b8bce8c4ba945924a4bfed5973a693`.
Exactly four old Haskell files and four new fixtures differ from the baseline; 912 originals, all 622
old fixtures and all other controls remain exact. Current fixture inventory is 626. Recorded test
reversals, 55 other relocated bodies and all 57 absent old homes, response22 plus the other Rooted
subjects, Handoff/Recovery/capability/path/response/Relay subjects and public/private metadata pass.

The canonical compiled Phase 1 covered-path digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`: query 0.187424 seconds,
wrapper 0.513062 seconds/exit 0 at 13:38:50.889852 to 13:38:51.439881 UTC. Phase 1 remains Done.
The final process/four-metadata audit passed at 13:39:26.097699 to 13:39:26.441743 UTC in
0.344048 seconds, parent 0. Original container StartedAt, init and both writable source/cache mounts
remain; only init, sleep and audit ps are present, with no surviving test/probe children. Git history
remains untouched. Earlier missing-import compilation is retained separately from the corrected
component/direct/focused/full successes; no gate was launched from that failed compilation.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T13:41:20.808150+00:00 to 2026-11-02T13:41:26.267822+00:00,
5.459688 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 13.46: Response session is one checked coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across Rooted and Relay; exactly one new named type
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give the existing kernel input role LifecycleSession its own checked opaque scalar, accepting nonempty UTF-8 within the existing encoded lifecycle-text bound.
This is one input-contract adoption. The five post-open request builders, nonce-only OpenFrame, Opened response
and broader descriptive fold-return adoption belong to Sprint 17.73's separately bounded caller work.

#### Deliverables

- Add only abstract `LifecycleSession`, hidden constructor, `mkLifecycleSession` and total
  `lifecycleSessionText` in Rooted. Reuse unchanged `requireLifecycleText "response session"`: Text is
  nonempty and its encoded UTF-8 length is at most 4096 bytes, with the existing exact refusal strings.
  The monomorphic scalar is inert DATA; no parameter-role annotation, authority or accepting raw adapter.
- Type only the session input of the six post-open response builders and private opaque helper. Adopt
  canonical reconstruction in the same two decoders after their existing raw session validation. The nine
  existing response declarations remain the bounded input-adoption set; RequestDigest stays unchanged.
  Opened, common validators, DATA shapes, callback/fold outputs and request pairing remain Text contracts.
- Adopt only the same two Relay callers: after the existing attached-session/post-open checks (and Prepared
  grant fold), retain RequestDigest construction first and wrap the existing retained session token inside
  the existing Either passed to signAndUse. The hidden frame-session producer derives that token as the
  SHA of its existing framed identity and preserves it through attach/advance. No session/authority producer,
  new IO, error-priority change or callback timing change is introduced.
- Preserve all four fixed positively named Rooted subjects, including response22/48fb, with their exact
  declared names and complete clause lists. Reuse requireLifecycleText without changing its request31 owner.
  Preserve Recovery a6, all five Handoff bundles, Relay's 4292-byte transport, capability/path/raw-response
  subjects, all other production modules, Cabal/projects and public/private inventories. No hash/count rebase.
- Add constructor/eliminator byte-boundary values: empty, ASCII4097, 2048 two-byte characters plus ASCII1,
  and 1025 four-byte characters refuse; ASCII4096, 2048 two-byte characters, 1024 four-byte characters and
  short mixed Text eliminate exactly. Adopt the six-builder byte table with one checked session supplied
  only to actual kernels; keep raw session in request construction and independent expected rendering.
  Adopt only current owned input/export/reconstruction source controls. Existing wire/crypto/order and
  pairing evidence remains exact.
- Add `RawTextAsRootedLifecycleSession.hs`, `CoerceRootedLifecycleSession.hs` and
  `ForgeRootedLifecycleSession.hs`. The actual Descend kernel receives an already typed RequestDigest;
  apply through its third/session argument to isolate the raw Text refusal. Its matching positive changes
  only that parameter type. Constructor negatives explicitly request `LifecycleSession(..)`; measure actual
  selected-five categories and complete phrases before registration. All 626 old fixture bytes initially
  stay exact. The two current RequestDigest inline positives explicitly adopt the LifecycleSession import
  and third-argument type; their Sprint 13.45 single-parameter relationship is dated evidence. Remeasure
  both immutable request negatives and retain their original request-specific refusals despite any extra
  returned-function mismatch; an incidental new session error cannot substitute for the named old reason.
- Update only the declared architecture document for the actual fourth inert scalar and six session inputs,
  distinguishing format from the existing frame-session provenance. Broader descriptive/request-builder,
  Opened and session/stage input work retain their own declared scopes.

#### Validation

HandoffSpec applies the real UTF-8 byte bound, exact valid elimination, current six-builder independent
wire/codec/request-pairing table and unchanged cryptographic/refusal controls. CompileFailSpec uses actual
selected-five arguments for the new raw-session/coerce/forge subjects, their matching positive and the two
adopted RequestDigest positives; it remeasures the unchanged old request negatives for their original named
reasons. No stage swap is claimed before Sprint 13.47 supplies that type. Main-only privacy, compiler
resolver/runner, complete diagnostic matcher and strict import grammar remain unchanged. Run the actual
focused HandoffSpec/public compile-fail/indexed project-plan foundation/DocValidatorSpec selection, then
all four host static commands. Record actual scope, constructor/caller boundaries and results; the phase's
separate gate remains due at phase closure.

Dated 2026-11-02 pre-edit baseline at 13:41:50.657853 UTC captures 35 texts, 920 Haskell files and
626 canonical fixtures outside the repository. Rooted is
`c3cd9d295ba555c3b502224b308a5d58d29a5b8f02adc6c1faee007852a5583a`; Relay is
`316928821f3ea1f5c4d5f6e5f3a76499cea157d341c3d2f456144edae6f751ef`.
Before any source/test edit, a Temp helper using actual unchanged 100 selected-five compiler arguments,
current SourceGuard signature/plural-clause readers and compiled childConfigDigest/Aeson serialization
built at 13:42:33.154261 to 13:42:36.745411 UTC in 3.591154 seconds, exit 0/empty stderr.
The saved baseline/current measurement passed at 13:42:36.745428 to 13:42:37.694341 UTC in
0.948912 seconds, exit 0/empty stderr, with exact frozen source/metadata and actual entries/bytes equal.
Shape/role, request31, response22 and shared20 subjects retain 1351/16871/20240/4189 Aeson bytes and
fixed respective digests `2f669c249c2291c98b4ce57e0b307479b2be669834e823d60b7683f22b19ae42`,
`5460d05bf207b1fe47943a2eed3cd7c54ebfdaee39e29fc143316ee4c43c70ae`,
`48fbcb826f5bae7f727276a3950e05679bda7fd9892250e00dd634e1cbdd9b6f`, and
`50411bdbff15a847d7550bd78b189104ca05fadd593467a7039e237889a2cf11`.
The response22 set keeps its exact positive names/order and actual decodeResponsePost two clauses;
requireLifecycleText remains in the unchanged request31 set. No whole/complement or fabricated expected
rows are measured. Current caller analysis locates the hidden token producer and retained-token folds in
Lifecycle.Rooted; its actual 64-character ASCII SHA token is lawful under the existing encoded-byte bound.
Implementation, compiler proof and all declared gates remain owed.

Dated 2026-11-02 production freeze: exactly one LifecycleSession, 61 changed nonempty / 64 physical
lines across Rooted (52/55) and Relay (9/9). Frozen SHA-256 values are
`6bd449414f644443c6615f9938432ba63fb56f4ddd4419208a2fb326500b5caf` and
`bd6d86871a0b2ebf4190156cf1db42b8ad402f79fcc0fb8e96e949190f4af527`.
Independent production reviews pass: all four fixed subjects, whole Handoff and other production/Cabal
bytes remain unchanged; RequestDigest construction precedes session wrapping after old caller evidence,
and canonical wrapping follows existing raw validation without changing callback/fold/error/IO contracts.
Native `cabal build all` from core passed at 13:48:31.556201 to 13:48:50.829256 UTC in
19.273170 seconds, parent 0/empty stderr, with frozen production and metadata exact.

Eight probes use the actual unchanged 100 selected-five compiler arguments. All declared outcomes pass
at 13:49:50.531784 to 13:49:51.703573 UTC:

| Actual source | Exit | Seconds | Named outcome |
|---|---:|---:|---|
| Session typed positive | 0 | 0.159944 | Empty stderr |
| Adopted request typed positive | 0 | 0.153562 | Empty stderr |
| Adopted distinct-Payload request positive | 0 | 0.160001 | Empty stderr |
| RawTextAsRootedLifecycleSession.hs | 1 | 0.153457 | One GHC-83865 block: expected LifecycleSession / actual Text at real third argument |
| CoerceRootedLifecycleSession.hs | 1 | 0.125249 | One complete GHC-18872 representation block with hidden-constructor note |
| ForgeRootedLifecycleSession.hs | 1 | 0.120433 | GHC-01928: illegal term-level use of LifecycleSession |
| Immutable RawTextAsRootedRequestDigest.hs | 1 | 0.143569 | Original request/Text GHC-83865 phrase retained in the second diagnostic block |
| Immutable PayloadDigestAsRootedRequestDigest.hs | 1 | 0.151804 | Original request/PayloadDigest GHC-83865 phrase retained in the second diagnostic block |

The old request negatives additionally report their changed returned-function session/Text mismatch in a
separate first block. That incidental error cannot satisfy either original request-specific phrase;
both original registrations and all 626 old fixture bytes remain exact. Constructor negatives request
LifecycleSession(..) and reach the intended errors without import warning/error. The new session positive
differs only in the session parameter; both current request positives adopt only their declared session
import/third-argument type. Actual source and compiler metadata hashes remain frozen. Measured subjects:

- RootedLifecycleSessionTypedInput: `10308884386308cd3ab951b4a95fd56cde0324106c846c0327ea89ad29ff38fe`.
- RootedRequestDigestTypedInput: `fd3e8e721144a0645a5019427db543419bbe5904ef0421342c646a58b4f6f906`.
- RootedRequestDigestDistinctPayloadInput: `e9f25bbeb471763d9af9b5386a1343065f773d7df30f42a9178f9e29bd6310ff`.
- RawTextAsRootedLifecycleSession.hs: `42f09c7fa1e7789508fa16303008725d4adcb36ffcb802463d62b7d3b4ceb787`.
- CoerceRootedLifecycleSession.hs: `d32dc1f679942767a73af18e7b25195ceaebbeed3bb6031e5883fd21a1caccac`.
- ForgeRootedLifecycleSession.hs: `9e44e9ae54303bd78e236a85cac5b81aa06fdddf6e4e28e430dfad8aa83cba10`.
- RawTextAsRootedRequestDigest.hs: `720808ab7ac73c6d22a642d2812773c2d3387711d298a904fad272e5dbb736a9`.
- PayloadDigestAsRootedRequestDigest.hs: `3822b26c2e34b8808969a20f4c97a00366c8f205278abba6be260000da6dd4d9`.

Final test sources are frozen at HandoffSpec `82e714ac6ba17d41888bd802887fc428f72c0b5511b322c9fc86ec2947db3107`
and CompileFailSpec `2b0a7053abae30bb4a6e19090e7a9857ceea41c4c05d93003ca1866ead164c6d`.
Test compilation, focused validation and all four host static commands remain owed.

The native test-component build passed at 13:51:07.190972 to 13:52:01.727651 UTC in
54.536997 seconds, parent 0/empty stderr, actual linked rts_thr, with frozen source/metadata exact.
Final test audit passes at 146 changed nonempty / 152 physical lines: HandoffSpec (96/96),
CompileFailSpec (32/32) and three new fixtures (18/24). All 189 old labels remain with one new case;
all 18 prior hash occurrences and the complete preservation-helper suffix remain byte-identical.
Both complete test-module reversals restore their baselines; all 626 old fixtures, 916 unrelated
Haskell files and Cabal/projects remain exact. The six-builder table changes only actual-kernel checked
session inputs, while raw requests/expected bytes remain exact. Existing request-positive changes
reverse exactly to the prior literals. Focused and all-four validation remain due.

Dated 2026-11-02 final validation: all 32 direct cases passed at 13:53:03.664655 to
13:53:17.254642 UTC in 13.40 reported / 13.590050 wall seconds. Full focused validation passed
all 1065 cases at 13:53:17.471761 to 13:56:30.393708 UTC in 192.81 reported / 192.923108
wall seconds. Both parents exited 0 with empty stderr and exact frozen source/compiler metadata.
Reciprocal test review confirms the real encoded-byte counts, exact current positive literals, original
request-specific diagnostics in their own second blocks and all declared source preservation boundaries.

The reviewed frozen snapshot passed exactly one unfiltered Linux x86_64 host static gate with
GHC 9.12.4, Cabal 3.16.1.0 and default -Werror. Reporting flags select no tests.

| Command and root | Explicit result | Reported test seconds | Command seconds | Parent exit |
|---|---|---:|---:|---:|
| `cabal test all --test-show-details=direct --test-options=--hide-successes`, core | All 3904; Cabal PASS | 314.43 | 412.7667825 | 0 |
| Same unfiltered Cabal command, demo | All 165 demo plus All 3904 included core; Cabal PASS | 1.76 plus 314.45 | 408.6367663 | 0 |
| `poetry run python -m hostbootstrap.check_code`, repository root | Ruff, Black and Mypy passed | N/A | 0.8557717 | 0 |
| `poetry run python -m hostbootstrap.test_all`, repository root | All 376; 100% statement and branch coverage | 5.95 | 7.1318043 | 0 |

Core ran 13:57:16.609102 to 14:04:09.373385 UTC; demo ran 13:57:16.609173 to
14:04:05.243464 UTC. Checks ran 13:57:16.609022 to 13:57:17.464809 UTC; Python tests ran
13:57:16.609300 to 13:57:23.741078 UTC. Both core outputs explicitly measured 26 conditional
families, 62 supported rows and 21 refusals, including the actual root case `(1,0)`. Python measured
1585 statements and 460 branches with zero misses/partial branches. Provider-live default not-requested
wrappers passed; this static gate makes no physical-provider acceptance claim.

The root synchronized and verified exactly ten changed files at 13:54:31.397290 to
13:54:31.509926 UTC, 0.112619 seconds/exit 0. A native/Linux comparison of 1048 source/Python/
document/metadata files and the exact 923-Haskell-file directory set passed before gate launch at
13:55:38.136192 to 13:55:38.423707 UTC, 0.287496 seconds/exit 0. Independent preservation
preflight passed at 13:56:27.816635 to 13:56:41.352414 UTC, 13.535776 body / 19.045842 outer
seconds, parent 0. All source/prose remained held through full validation and final audits.

Final post-gate source/fixture/document/metadata audit passed at 14:04:55.526626 to
14:05:09.050990 UTC, 13.524358 body / 19.152577 outer seconds, parent 0. All 923 Haskell files
match `9aaea2d58ac24ed871965075740e2a98715a06644d91ca9186ec6ff77ec1c6c8`; the 898 core
source/internal/test files match
`6c5f4667c75649dd2ace7c9c41d64565c9f897255597bac2836563598a826337`; the 95 held governed
documents match `a7f2cefb8f861a4d6efe59c57d9bcd9e8e1d0adc3c6650041bffecd3335bf461`.
Only the four declared old Haskell files and three new fixtures differ from baseline; 916 originals,
all 626 old fixture bytes and other preservation subjects remain exact. Current fixture inventory is
629. Both complete test-module rollbacks, all 18 hash occurrences, the entire preservation-helper
suffix, four Rooted subjects, whole Handoff/Recovery/capability/path/raw-response/Relay subjects,
109 path arrays and public/private metadata pass. All other relocated bodies and absent old homes
retain their declared boundaries. Production and both old request-negative registrations are unchanged
after the recorded compiler proofs; their additional session mismatch does not substitute for the
original named request refusal.

Canonical compiled Phase 1 digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`: query 0.228499 seconds,
wrapper 0.593761 seconds/exit 0 at 14:04:55.412243 to 14:04:56.048447 UTC. Phase 1 stays Done.
Final process/four-metadata audit passed at 14:05:15.290886 to 14:05:15.679759 UTC in
0.388879 seconds, parent 0. Original container StartedAt, init and both writable source/cache mounts
remain, with only init, sleep and audit ps present and no surviving test/probe children. Git history
remains untouched. No gate was repeated and no source correction was needed after the frozen build.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T14:06:23.736331+00:00 to 2026-11-02T14:06:29.548509+00:00,
5.812194 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 13.47: Response stage is distinct from its session [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across Rooted and Relay; exactly one new named type
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give the existing kernel input role LifecycleStage its own checked opaque scalar, accepting nonempty UTF-8 within the existing encoded lifecycle-text bound.
This is one input-contract adoption. The five post-open request builders, nonce-only OpenFrame, Opened response
and broader descriptive fold-return adoption belong to Sprint 17.73's separately bounded caller work.

#### Deliverables

- Add only abstract `LifecycleStage`, hidden constructor, `mkLifecycleStage` and total
  `lifecycleStageText` in Rooted. Reuse unchanged `requireLifecycleText "response stage"`: nonempty
  Text with at most 4096 encoded UTF-8 bytes and the exact existing empty/oversized-stage errors.
  This monomorphic scalar is inert DATA, with no parameter-role annotation, authority or raw accepting API.
  Its format check adds no enum/membership test and grants no lifecycle-state transition.
- Type the fourth/stage input of the six post-open response builders and private opaque helper. Adopt
  canonical reconstruction in the same two decoders only after existing raw stage validation. The nine
  existing declarations remain the bounded adoption set; existing RequestDigest/LifecycleSession stay exact.
  Opened, common validators, DATA shapes, callback/fold outputs and request pairing remain Text contracts.
- Adopt only the same two Relay callers inside their existing Either after old attached-session/post-open
  checks and Prepared's grant fold: RequestDigest first, LifecycleSession second, LifecycleStage third.
  Prepared's stage is its existing literal; generic stages come from the existing closed family selection,
  never the ignored stored-session stage. Keep postOpenNonce and the generic family's own refusal separate
  and exact, including its existing refusal of Prepared. All opaque bodies, error/callback/IO order remain.
- Preserve all four fixed positively named Rooted subjects (including response22/48fb), their complete
  clause lists and requireLifecycleText's request31 owner. Keep Recovery a6, all five Handoff bundles,
  Relay's 4292-byte transport, capability/path/raw-response subjects, other production modules, Cabal/projects,
  private/public inventories and old labels exact. No digest, global count or complement is rebased.
- Add the actual UTF-8 byte-boundary constructor/eliminator matrix using ASCII source escapes: the same
  empty/4097-ASCII/two-byte-over/four-byte-over refusals and exact4096/mixed positives as the session contract.
  Adopt the six-builder table with checkedStage only at actual kernels; raw stage/request/expected bytes
  remain exact. Adopt only owned input/export/reconstruction/caller source controls and retain all wire,
  cryptographic, pairing, refusal-order and preservation evidence.
- Add `SwapLifecycleSessionStage.hs` at the actual rootedSettledResponseUnsignedKernel with RequestDigest
  already typed: exchange the actual session/stage arguments; the matching positive fixes only those callee
  arguments. Add `RawTextAsRootedLifecycleStage.hs` applied through slot4 with RequestDigest and LifecycleSession
  already typed; its positive changes only the stage parameter. Add `CoerceRootedLifecycleStage.hs` and
  `ForgeRootedLifecycleStage.hs` with plain `LifecycleStage(..)` imports. Measure actual categories and
  complete per-block phrases before registration. All 629 old fixtures initially stay byte-identical.
  Three current request/session inline positives explicitly adopt the LifecycleStage import and fourth-slot
  type; earlier single-parameter relations remain dated evidence. Remeasure both original request refusals
  and the original raw-session refusal in their individual blocks; incidental returned-stage errors cannot
  satisfy an old named reason. Existing diagnostic matcher/resolver/runner/import grammar remain unchanged.
- Update only the declared architecture document for this fifth inert scalar, exact format bound, six
  stage inputs and actual literal/closed-family provenance. Keep descriptive/request-builder/Opened scopes
  and all authority/state-transition contracts explicit and separate.

#### Validation

HandoffSpec checks real encoded-byte counts, exact accepted elimination, six actual typed-builder bytes,
codec and request pairing against unchanged independent raw rendering, and all fixed source/crypto controls.
CompileFailSpec uses actual selected-five arguments for a genuine two-role session/stage swap, raw fourth
argument, coercion and constructor forgery, matching positives and three explicitly adopted current API
controls. Reprobe the unchanged old request/session negatives for their original named reasons. Main-only
privacy and every generic compiler/inventory control remain exact. Run actual focused HandoffSpec/public
compile-fail/indexed project-plan foundation/DocValidatorSpec, then all four host static commands; record
actual scope/results. The phase's separate gate remains due at phase closure.

Dated 2026-11-02 pre-edit baseline at 14:07:17.766557 UTC captures 35 texts, 923 Haskell files and
629 fixtures outside the repository. Rooted is
`6bd449414f644443c6615f9938432ba63fb56f4ddd4419208a2fb326500b5caf`; Relay is
`bd6d86871a0b2ebf4190156cf1db42b8ad402f79fcc0fb8e96e949190f4af527`.
Before source/test edits, the Temp actual-100-argument SourceGuard/Aeson helper built at
14:08:51.778460 to 14:08:55.956733 UTC in 4.178279 seconds, exit 0/empty stderr. The saved
baseline/current measurement passed at 14:08:55.956749 to 14:08:56.953968 UTC in 0.997217
seconds, exit 0/empty stderr, with all actual entries/serialized bytes and frozen source/metadata equal.
Shape/role, request31, response22 and shared20 subjects retain 1351/16871/20240/4189 Aeson bytes
and respective fixed digests `2f669c249c2291c98b4ce57e0b307479b2be669834e823d60b7683f22b19ae42`,
`5460d05bf207b1fe47943a2eed3cd7c54ebfdaee39e29fc143316ee4c43c70ae`,
`48fbcb826f5bae7f727276a3950e05679bda7fd9892250e00dd634e1cbdd9b6f`, and
`50411bdbff15a847d7550bd78b189104ca05fadd593467a7039e237889a2cf11`.
The exact positive names/order and plural clauses remain fixed; no whole/complement or fabricated rows
are measured. Current caller review identifies Prepared's literal and the generic closed-family values,
all short lawful ASCII, preserving the existing independent generic-family refusal. Implementation and
all declared compiler/focused/full gates remain owed.

Dated 2026-11-02 production freeze: exactly one LifecycleStage, 66 changed nonempty / 69 physical
lines across Rooted (52/55) and Relay (14/14). Frozen source hashes are
`ff5d8ca936bac7b4f9566bdc6b238c43e79508e76484f88cd2a0e92ba9935518` and
`44814f1914810365c85f28f66229fc225f1d58f9057888d9d3c950176f936e9f`.
Independent initial production review passes the declared source/type/caller scope, with exact old
Prepared literal/closed-family provenance and unchanged raw callbacks/common/fold/pair/IO contracts.
Native `cabal build all` from core passed at 14:14:35.705604 to 14:14:54.704911 UTC in
18.999427 seconds, parent 0/empty stderr, with frozen production and metadata exact.

Twelve actual selected-five probes use the unchanged measured 100 compiler arguments. All declared
outcomes pass at 14:16:23.935970 to 14:16:25.540376 UTC:

| Actual source | Exit | Seconds | Named outcome |
|---|---:|---:|---|
| RootedLifecycleSessionStageTypedInputs | 0 | 0.152519 | Typed positive, empty stderr |
| RootedLifecycleStageTypedInput | 0 | 0.131921 | Typed positive, empty stderr |
| RootedRequestDigestTypedInput | 0 | 0.141055 | Typed positive, empty stderr |
| RootedRequestDigestDistinctPayloadInput | 0 | 0.135657 | Typed positive, empty stderr |
| RootedLifecycleSessionTypedInput | 0 | 0.127117 | Typed positive, empty stderr |
| SwapLifecycleSessionStage.hs | 1 | 0.142814 | Two distinct GHC-83865 blocks, expected Session/actual Stage and expected Stage/actual Session |
| RawTextAsRootedLifecycleStage.hs | 1 | 0.144873 | One GHC-83865 block: expected LifecycleStage/actual Text at real fourth argument |
| CoerceRootedLifecycleStage.hs | 1 | 0.112605 | One complete GHC-18872 representation block with hidden-constructor note |
| ForgeRootedLifecycleStage.hs | 1 | 0.107296 | GHC-01928 illegal term-level LifecycleStage use |
| RawTextAsRootedRequestDigest.hs | 1 | 0.135423 | Original named request/session reason retained in its own GHC-83865 block |
| PayloadDigestAsRootedRequestDigest.hs | 1 | 0.132070 | Original named request/session reason retained in its own GHC-83865 block |
| RawTextAsRootedLifecycleSession.hs | 1 | 0.132585 | Original named request/session reason retained in its own GHC-83865 block |

The swap positive differs only in its two callee arguments; the raw-stage positive differs only in the
stage parameter type. Three prior current positives adopt only the declared Stage import/fourth-slot
type. Constructor subjects request LifecycleStage(..) and reach the intended errors without import
warning/error. Each immutable old negative additionally reports a returned-function mismatch in a
separate block; the original request/session-specific phrase remains and cannot be replaced by that
incidental new error. All 629 old fixtures and original registrations remain exact. Actual probe
source/compiler metadata hashes stay frozen. Measured subjects:

- RootedLifecycleSessionStageTypedInputs: `914c5903e68c9dcb73b4156c49f98e9918996eee4430e63748ea7e140971e3d7`.
- RootedLifecycleStageTypedInput: `8e4c96f324e02088d31f2777561adda3ee4e09c7c5e752c1abcb1fd4572cf87e`.
- RootedRequestDigestTypedInput: `e4691dcb1b6684c48d4b900c5a14bc84026437f9685275769ae041a546e6012e`.
- RootedRequestDigestDistinctPayloadInput: `f7839bba55f7394df3a8b8838bfe8872857756239c5933fe7ee486e45308ec08`.
- RootedLifecycleSessionTypedInput: `5c442d52ad9d5340e13fbf7425fb1e1757c06cc894c96482fcd073c65badc17b`.
- SwapLifecycleSessionStage.hs: `2e756bd8c9a15fcf68f17a0809500d5f83efdd381fd5c0506076c121f1660b93`.
- RawTextAsRootedLifecycleStage.hs: `ad6226af31984500c20e4b32c1c23db1fb0f73816bedd4626791599669eb9754`.
- CoerceRootedLifecycleStage.hs: `b83977c561b5d652695fdeaf445a78149098c051a119d66ad1cd963ac1b7e41c`.
- ForgeRootedLifecycleStage.hs: `b27a68556c97ef32ac6ababf7d5871e2f8c1b605ac72d5fe93989514c00f4c93`.
- RawTextAsRootedRequestDigest.hs: `720808ab7ac73c6d22a642d2812773c2d3387711d298a904fad272e5dbb736a9`.
- PayloadDigestAsRootedRequestDigest.hs: `3822b26c2e34b8808969a20f4c97a00366c8f205278abba6be260000da6dd4d9`.
- RawTextAsRootedLifecycleSession.hs: `42f09c7fa1e7789508fa16303008725d4adcb36ffcb802463d62b7d3b4ceb787`.

Test compilation and all declared focused/full gates remain owed.

Native test-component build passed at 14:17:30.609097 to 14:18:24.444414 UTC in
53.835657 seconds, parent 0/empty stderr, actual linked rts_thr and exact frozen source/metadata.
Final test audit passes at 182 changed nonempty / 190 physical lines: HandoffSpec (101/101),
CompileFailSpec (55/55) and four new fixtures (26/34). Frozen test hashes are
`a1040db50fd5afe602e685c5494519c332433021735ebfe80b04fa4800fbdb8a` and
`67b2ba9f04f8d9a4bc0bf9334d36d299734b981519aa9c3344b2238e46e61951`.
All 190 old labels remain with one new case; all 18 prior hash occurrences and the complete
preservation-helper suffix are byte-identical. Both exact full-module reversals restore baselines;
all 629 old fixtures, 919 unrelated Haskell files and Cabal/projects remain exact. Six-builder raw
requests/stages/expected bytes remain exact; only actual inputs use checkedStage. Five positive
literals match the measured sources and prior three caller adoptions reverse exactly. Focused and
all-four validation remain owed.

Dated 2026-11-02 final focused validation: all 39 direct cases passed at 14:19:52.027762 to
14:20:05.703468 UTC in 13.51 reported / 13.675773 wall seconds. Full focused validation passed
all 1072 cases at 14:20:05.926155 to 14:23:03.088933 UTC in 177.01 reported / 177.163877
wall seconds. Both parents exited 0 with empty stderr and exact source/compiler metadata. Final
reciprocal production/test/document reviews pass the real swap, UTF-8 matrix, exact current positives,
original earlier named refusals and all declared caller/preservation scopes.

Exactly one unfiltered Linux x86_64 host static gate passed on the reviewed frozen snapshot with
GHC 9.12.4, Cabal 3.16.1.0 and default -Werror. Reporting flags select no tests.

| Command and root | Explicit result | Reported test seconds | Command seconds | Parent exit |
|---|---|---:|---:|---:|
| `cabal test all --test-show-details=direct --test-options=--hide-successes`, core | All 3911; Cabal PASS | 267.44 | 356.3461275 | 0 |
| Same unfiltered Cabal command, demo | All 165 demo plus All 3911 included core; Cabal PASS | 1.42 plus 266.06 | 352.5179222 | 0 |
| `poetry run python -m hostbootstrap.check_code`, repository root | Ruff, Black and Mypy passed | N/A | 0.7497007 | 0 |
| `poetry run python -m hostbootstrap.test_all`, repository root | All 376; 100% statement and branch coverage | 5.61 | 6.6592962 | 0 |

Core ran 14:24:27.372413 to 14:30:23.716310 UTC; demo ran 14:24:27.372275 to
14:30:19.887995 UTC. Checks ran 14:24:27.372153 to 14:24:28.121868 UTC; Python tests ran
14:24:27.386067 to 14:24:34.045341 UTC. Both core outputs explicitly recorded 26 conditional
families, 62 supported rows and 21 refusals, including the actual root case `(1,0)`. Python measured
1585 statements and 460 branches with zero misses/partial branches. Provider-live default not-requested
wrappers passed; this static gate makes no physical-provider acceptance claim.

The root synchronized and verified eleven changed files at 14:21:13.846317 to 14:21:13.952297
UTC, 0.105964 seconds/exit 0. A native/Linux comparison of 1052 source/Python/document/metadata
files and the exact 927-Haskell-file directory set passed before the gate at 14:21:14.300588 to
14:21:14.553018 UTC, 0.252412 seconds/exit 0. Independent preservation preflight passed at
14:22:30.403901 to 14:22:42.385611 UTC, 11.981708 body / 16.961994 outer seconds, parent 0.
All source/prose remained held through full validation and post-gate audits.

Final source/fixture/document/metadata audit passed at 14:31:51.307067 to 14:32:03.660241
UTC, 12.353172 body / 17.265502 outer seconds, parent 0. All 927 Haskell files match
`37acb5798ce20815dd1d3fe59368e162e030c34b2c9cf12e42944288aa064ad9`; the 902 core
source/internal/test files match
`9753ac07c512302ecbdc66186bf9be20751a87c3dd07647ed2f565224003abe3`; the 95 held governed
documents match `c5fdb207a39d9fcd7c43ffde3d7430808dda72a99a0f4bcaaf4b61e9b5128113`.
Only the four declared old Haskell files and four new fixtures differ from baseline; 919 originals,
all 629 old fixture bytes and other controls remain exact. Current inventory is 633 fixtures. Exact
full-module reversals, all 18 hashes, the complete preservation-helper suffix, four Rooted subjects,
whole Handoff/Recovery/capability/path/raw-response/Relay subjects, 109 path arrays, unchanged other
relocated bodies/absent old homes and all public/private metadata pass. All three earlier named compiler
refusals and original registration rows remain exact despite their additional returned-function errors.

Canonical compiled Phase 1 digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`: query 0.189068 seconds,
wrapper 0.515624 seconds/exit 0 at 14:31:51.197297 to 14:31:51.751811 UTC. Phase 1 stays Done.
Final process/four-metadata audit passed at 14:32:06.856765 to 14:32:07.238136 UTC in
0.381377 seconds, parent 0. Original container StartedAt, init and both writable source/cache mounts
remain, with only init, sleep and audit ps present and no surviving test/probe children. Git history
remains untouched. No gate was repeated and no source correction followed the frozen build.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T14:33:29.575047+00:00 to 2026-11-02T14:33:35.260157+00:00,
5.685129 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 13.48: Response ordinal is a checked nonzero coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across Rooted and Relay; exactly one new named type
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give the existing kernel input role LifecycleOrdinal its own checked opaque scalar, accepting nonzero Word64.
This is one input-contract adoption. The five post-open request builders, nonce-only OpenFrame, Opened response
and broader descriptive fold-return adoption belong to Sprint 17.73's separately bounded caller work.

#### Deliverables

- Add only abstract `LifecycleOrdinal`, hidden constructor, `mkLifecycleOrdinal :: Word64 -> Either Text LifecycleOrdinal`
  and total `lifecycleOrdinalWord64`. Apply only the existing nonzero predicate and exact response error
  `has a zero response ordinal`; 1 through maxBound are admitted. Use inert monomorphic Eq/Show DATA,
  no numeric-construction instance, parameter-role annotation, authority or accepting raw adapter.
- Type only the ordinal input of the six post-open response builders and private opaque helper. Adopt
  reconstruction in the same two decoders after existing raw ordinal validation. The nine declarations
  remain the bounded set; prior checked scalars stay exact. Opened/common validators/DATA shapes/folds/
  callbacks/pairing keep Word64. Preserve raw decodeLifecycleOrdinal's width/nonzero check and distinct
  `has a zero ordinal` error, and introduce no upper bound or new overflow policy.
- Adopt only the same two Relay callers with their actual existing `(ordinal + 1)` expressions. Prepared
  wraps after prior evidence and RequestDigest/Session/Stage inside its existing Either. Generic response
  family selection occurs BEFORE any ordinal factory: wrap only in selected Receipt/Refused arms and the
  existing selected opaque helper (or an equivalently bounded selected-arm helper). Keep wildcard fallback
  exact. postOpenNonce can admit Prepared although generic build refuses it; even when successor wraps0,
  the old generic-family refusal must retain priority. Error prefixes, callback/IO order and bodies remain.
- Preserve all four fixed Rooted subjects and complete clause lists, including raw common validators and
  decodeLifecycleOrdinal's request31 owner. Keep all prior scalar APIs, Recovery a6, five Handoff bundles,
  Relay's 4292-byte transport, capability/path/raw-response controls, other production/Cabal/project bytes,
  public/private inventories and old labels exact. No hash/count/complement rebase.
- Add pure DATA checks: zero refuses, 1/maxBound eliminate exactly, ordinary Word64 maxBound+1 equals0
  and that zero keeps the existing refusal. Adopt the six-builder table with checkedOrdinal2 only at
  kernels; independent raw response2/request1 bytes remain exact. Owned source controls prove generic
  case selection precedes selected-arm ordinal wrapping and wildcard contains no new validation. These
  are source/pure-DATA checks; no fabricated live maxBound frame-session callback is claimed.
- Add `RawWord64AsRootedLifecycleOrdinal.hs` at actual Descend through slot5 with prior roles typed;
  its positive changes only the ordinal parameter type. Reexport Word64 and LifecycleOrdinal so identical
  imports remain used. Add `CoerceRootedLifecycleOrdinal.hs` and `ForgeRootedLifecycleOrdinal.hs` from
  Word64 with plain `LifecycleOrdinal(..)` imports. Measure real categories/complete per-block phrases.
  Five current inline builder positives explicitly add LifecycleOrdinal to Rooted imports, type slot5 and
  remove the Data.Word(Word64) import now unused there; their bodies remain exact. All 633 old canonical
  fixtures initially stay byte-identical. Remeasure all six original named reasons across the two request,
  raw-session, raw-stage and two-direction swap negatives; new ordinal errors cannot substitute for them.
- Update only the declared architecture document for the sixth inert nonzero scalar, admitted maxBound,
  unchanged Word64 wrap/refusal behavior and actual caller ordering. Keep descriptive/request-builder/
  Opened and authority/state-transition contracts separate; no overflow prevention claim is added.

#### Validation

HandoffSpec applies actual nonzero factory/elimination/ordinary Word64 arithmetic, existing six-builder
wire/codec/request-pairing controls and unchanged preservation subjects. Source checks hold selected-family
validation/fallback ordering without inventing live authority fixtures. CompileFailSpec uses actual selected-five
arguments for rawWord64/coerce/forge, matching positive and the five explicitly adopted current API controls;
reprobe six earlier named reasons in their own blocks. Main-only privacy and generic compiler/matcher/import
controls remain exact. Run actual focused HandoffSpec/public compile-fail/indexed project-plan foundation/
DocValidatorSpec, then all four host static commands; record actual scope and results. The phase's separate
gate remains due at phase closure.

Dated 2026-11-02 pre-edit baseline at 14:34:26.071690 UTC captures 35 texts, 927 Haskell files and
633 fixtures outside the repository. Rooted is
`ff5d8ca936bac7b4f9566bdc6b238c43e79508e76484f88cd2a0e92ba9935518`; Relay is
`44814f1914810365c85f28f66229fc225f1d58f9057888d9d3c950176f936e9f`.
The Temp actual-100-argument SourceGuard/Aeson helper built before source/test edits at
14:35:52.285194 to 14:35:55.824803 UTC in 3.539614 seconds, exit0/empty stderr. Saved/current
measurement passed at 14:35:55.824818 to 14:35:56.777667 UTC in 0.952847 seconds, exit0/empty
stderr, with actual entries/serialized bytes and all frozen source/metadata equal. Shape/role, request31,
response22 and shared20 retain 1351/16871/20240/4189 Aeson bytes and respective fixed digests
`2f669c249c2291c98b4ce57e0b307479b2be669834e823d60b7683f22b19ae42`,
`5460d05bf207b1fe47943a2eed3cd7c54ebfdaee39e29fc143316ee4c43c70ae`,
`48fbcb826f5bae7f727276a3950e05679bda7fd9892250e00dd634e1cbdd9b6f`, and
`50411bdbff15a847d7550bd78b189104ca05fadd593467a7039e237889a2cf11`.
Exact positive names/order and complete plural clauses remain fixed; no fabricated expected rows are used.
Caller review identifies initial ordinal1, retained attachment and advancement of decoded successors only
when successor>old; maxBound itself is admitted. The separate generic-family fallback precedes any actual
Rooted ordinal check, which is why selected-arm placement is part of this contract. Implementation and
all declared compiler/focused/full gates remain owed.

Dated 2026-11-02 production freeze: exactly one LifecycleOrdinal, 69 changed nonempty / 72 physical
lines across Rooted (52/55) and Relay (17/17). Frozen source SHA-256 values are
`075487a7b7e376bb7a4399f742936b2ae72064cef7452df74f9a03ec369c09e8` and
`ccfa05c752c97e9bfe21bccead46022f72f4c16134a3a99eab74abbb04d00948`.
Independent production reviews pass: nonzero-only factory, no numeric constructors/new overflow law,
all prior APIs/raw decoder and four fixed subjects intact. Generic complete prefix before family case
and wildcard are raw-exact; ordinal checks occur only in selected arms/helper, while Prepared checks
follow prior evidence/scalars. Native `cabal build all` from core passed at 14:41:34.163741 to
14:41:52.803489 UTC in 18.639865 seconds, parent 0/empty stderr, with frozen production/metadata exact.

Fourteen actual selected-five probes use the unchanged measured 100 arguments. All declared outcomes
pass at 14:43:52.773298 to 14:43:54.694656 UTC:

| Actual source | Exit | Seconds | Named outcome |
|---|---:|---:|---|
| RootedLifecycleOrdinalTypedInput | 0 | 0.149759 | Exact current typed positive, empty stderr |
| RootedRequestDigestTypedInput | 0 | 0.138658 | Exact current typed positive, empty stderr |
| RootedRequestDigestDistinctPayloadInput | 0 | 0.127627 | Exact current typed positive, empty stderr |
| RootedLifecycleSessionTypedInput | 0 | 0.126732 | Exact current typed positive, empty stderr |
| RootedLifecycleSessionStageTypedInputs | 0 | 0.134711 | Exact current typed positive, empty stderr |
| RootedLifecycleStageTypedInput | 0 | 0.128214 | Exact current typed positive, empty stderr |
| RawWord64AsRootedLifecycleOrdinal.hs | 1 | 0.141665 | One GHC-83865 block, expected LifecycleOrdinal/actual Word64 at real fifth argument |
| CoerceRootedLifecycleOrdinal.hs | 1 | 0.126448 | One complete GHC-18872 Word64 representation/hidden-constructor block |
| ForgeRootedLifecycleOrdinal.hs | 1 | 0.147802 | GHC-01928 illegal term-level LifecycleOrdinal use |
| RawTextAsRootedRequestDigest.hs | 1 | 0.147352 | Original request/session/stage reason retained in its own GHC-83865 block |
| PayloadDigestAsRootedRequestDigest.hs | 1 | 0.141060 | Original request/session/stage reason retained in its own GHC-83865 block |
| RawTextAsRootedLifecycleSession.hs | 1 | 0.135783 | Original request/session/stage reason retained in its own GHC-83865 block |
| RawTextAsRootedLifecycleStage.hs | 1 | 0.132285 | Original request/session/stage reason retained in its own GHC-83865 block |
| SwapLifecycleSessionStage.hs | 1 | 0.136904 | Both original swap reasons retained in two distinct GHC-83865 blocks; separate ordinal error also reported |

The new raw-ordinal positive differs only in its ordinal parameter and keeps identical imports used
through its Word64/LifecycleOrdinal module reexports. Five earlier controls adopt only the declared
Rooted import/fifth-slot type and removal of their unused Word64 import; their bodies remain exact.
Constructor subjects request LifecycleOrdinal(..) and reach named failures without import warnings.
All six required earlier reasons match individual distinct diagnostic blocks across the five immutable
old files; incidental returned-function/ordinal errors cannot substitute. All 633 old fixture bytes and
registration rows remain exact. Actual source/compiler metadata hashes stay frozen. Measured subjects:

- RootedLifecycleOrdinalTypedInput: `7e9799436eac27975db0b701a5b27cc9fcff5875e41560551c1f0f87c6393862`.
- RootedRequestDigestTypedInput: `00c3dad2aab6e64c5c6fd57ef15754f0eddce4df6dc10f8729c46f1645b451b1`.
- RootedRequestDigestDistinctPayloadInput: `07954134ac5bf4198d2b1407105813e94c6c26e5deff191eceab950b9b2df781`.
- RootedLifecycleSessionTypedInput: `ba55d37a7326f5c72c4b48ccbae1b0d64c77247d64ed133aea9402b235c27be8`.
- RootedLifecycleSessionStageTypedInputs: `73ce8dba769a8aa4494abe8f91f05471d14116aae3f39f28f3277f437fda460b`.
- RootedLifecycleStageTypedInput: `8160a1763a5c1b346f0ea85fe864de7431fa749c36d0bd97d993e0f95a289cdd`.
- RawWord64AsRootedLifecycleOrdinal.hs: `dce197dc120007fdeeb14559206714be99f877e61b6a35d012c7b146003d191e`.
- CoerceRootedLifecycleOrdinal.hs: `48562ac0d97d368a0670dcb1682d1b50943f7d8fbb33e3ed8f3b5b1a563f1808`.
- ForgeRootedLifecycleOrdinal.hs: `94ff079f40a5fd84698309bf19e4c381a8106a828783cf1b142e46e323e551d7`.
- RawTextAsRootedRequestDigest.hs: `720808ab7ac73c6d22a642d2812773c2d3387711d298a904fad272e5dbb736a9`.
- PayloadDigestAsRootedRequestDigest.hs: `3822b26c2e34b8808969a20f4c97a00366c8f205278abba6be260000da6dd4d9`.
- RawTextAsRootedLifecycleSession.hs: `42f09c7fa1e7789508fa16303008725d4adcb36ffcb802463d62b7d3b4ceb787`.
- RawTextAsRootedLifecycleStage.hs: `ad6226af31984500c20e4b32c1c23db1fb0f73816bedd4626791599669eb9754`.
- SwapLifecycleSessionStage.hs: `2e756bd8c9a15fcf68f17a0809500d5f83efdd381fd5c0506076c121f1660b93`.

Final test sources are frozen at HandoffSpec `f39ee0d53cca897c3a6818f8af50cf994d7130bd8a063812c5e69a69a986d5fd`
and CompileFailSpec `8e66f12549a9f8805545b6304ec0b42a7202a093125402f5153c5ab15160d160`.
Test compilation, focused and all-four validation remain owed.

Native test-component build passed at 14:45:48.761447 to 14:46:42.640381 UTC in
53.879276 seconds, parent 0/empty stderr, actual linked rts_thr and exact frozen source/metadata.
Final test hashes remain `f39ee0d53cca897c3a6818f8af50cf994d7130bd8a063812c5e69a69a986d5fd`
and `8e66f12549a9f8805545b6304ec0b42a7202a093125402f5153c5ab15160d160`.
Final/reciprocal test audit passes at 167 changed nonempty / 173 physical lines: HandoffSpec (100/100),
CompileFailSpec (49/49), three new fixtures (18/24). Both recorded complete-module reversals restore
immutable baselines; all 633 old fixtures, 923 unrelated Haskell files and Cabal/projects remain exact.
All 191 old labels remain with one new case, all 18 prior hashes and the entire fixed-helper suffix
remain byte-identical. Pure ordinal/builder/source-order evidence and all six older named refusals
match the actual compiler outcomes; no live maxBound session is claimed. Focused and all-four gates
remain due.

Dated 2026-11-02 final focused validation: all 44 direct cases passed at 14:47:52.271191 to
14:48:05.615764 UTC in 13.15 reported / 13.344640 wall seconds. Full focused validation passed
all 1077 cases at 14:48:05.824877 to 14:51:00.593644 UTC in 174.65 reported / 174.769851
wall seconds. Both parents exited 0 with empty stderr and exact frozen source/compiler metadata.
Final reciprocal reviews pass the nonzero/pure arithmetic cases, selected-arm/fallback ordering,
current positives and six older named reasons with distinct actual diagnostic-block assignments.

Exactly one unfiltered Linux x86_64 host static gate passed on the reviewed frozen snapshot with
GHC 9.12.4, Cabal 3.16.1.0 and default -Werror. Reporting flags select no tests.

| Command and root | Explicit result | Reported test seconds | Command seconds | Parent exit |
|---|---|---:|---:|---:|
| `cabal test all --test-show-details=direct --test-options=--hide-successes`, core | All 3916; Cabal PASS | 269.84 | 359.9082560 | 0 |
| Same unfiltered Cabal command, demo | All 165 demo plus All 3916 included core; Cabal PASS | 1.38 plus 269.33 | 356.6497237 | 0 |
| `poetry run python -m hostbootstrap.check_code`, repository root | Ruff, Black and Mypy passed | N/A | 0.7948855 | 0 |
| `poetry run python -m hostbootstrap.test_all`, repository root | All 376; 100% statement and branch coverage | 5.59 | 6.5867895 | 0 |

Core ran 14:52:30.937665 to 14:58:30.843669 UTC; demo ran 14:52:30.937312 to
14:58:27.584808 UTC. Checks ran 14:52:30.937553 to 14:52:31.732452 UTC; Python tests ran
14:52:30.952200 to 14:52:37.538968 UTC. Both core outputs explicitly recorded 26 conditional
families, 62 supported rows and 21 refusals, including the actual root case `(1,0)`. Python measured
1585 statements and 460 branches with zero misses/partial branches. Provider-live default not-requested
wrappers passed; these static runs make no physical-provider acceptance claim.

The root synchronized and verified ten changed files at 14:48:42.626049 to 14:48:42.727744 UTC,
0.101679 seconds/exit 0. A native/Linux comparison of 1055 source/Python/document/metadata files
and exact 930-Haskell-file directory set passed before the gate at 14:48:43.086211 to
14:48:43.336821 UTC, 0.250594 seconds/exit 0. Independent preservation preflight passed at
14:49:46.446276 to 14:49:58.573814 UTC, 12.127537 body / 17.148495 outer seconds, parent 0.
All source/prose remained held through full validation and post-gate audits.

Final source/fixture/document/metadata audit passed at 15:00:49.592707 to 15:01:01.859455 UTC,
12.266744 body / 17.346845 outer seconds, parent 0. All 930 Haskell files match
`3c50e5d6ffbf7954afe34a17936478451371a7ac64c253704ed5a6c8be841124`; the 905 core
source/internal/test files match
`c1ba691d5697457d3c284a76e3c819ab2efda87e8d4a20806babab604872c398`; the 95 held governed
documents match `e8463f3d44d8a36a7debaacfa54dfd59fb6eeda1e1258a52c16b3fc2b7c771d9`.
Only the four declared old Haskell files and three new fixtures differ from baseline; 923 originals,
all 633 old fixture bytes and independent controls remain exact. Current inventory is 636 fixtures.
Both complete module rollbacks, all 18 prior hashes, entire preservation-helper suffix, four Rooted
subjects, whole Handoff/Recovery/capability/path/raw-response/Relay subjects, generic prefix/fallback/
postOpenNonce, 109 paths, other relocated bodies/absent old homes and public/private metadata pass.
All six original earlier reasons match their own distinct diagnostic blocks; added ordinal errors
cannot satisfy their unchanged registrations. No live maxBound frame-session fixture is claimed.

Canonical compiled Phase 1 digest remains
`0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7`: query 0.186414 seconds,
wrapper 0.501006 seconds/exit 0 at 15:00:49.476269 to 15:00:50.016270 UTC. Phase 1 stays Done.
Final process/four-metadata audit passed at 15:01:05.855181 to 15:01:06.227547 UTC in
0.372373 seconds, parent 0. Original container StartedAt, init and both writable source/cache mounts
remain, with only init, sleep and audit ps present and no surviving test/probe children. Git history
remains untouched. No gate was repeated and no source correction followed the frozen build.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T15:05:39.144638+00:00 to 2026-11-02T15:05:44.497391+00:00,
5.352771 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 13.49: Receipt predecessor has its own checked digest role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines across Rooted and Relay; exactly one new named type
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give the existing kernel input role PredecessorDigest its own checked opaque scalar, accepting 64 lowercase hexadecimal characters.
This is one input-contract adoption. The five post-open request builders, nonce-only OpenFrame, Opened response
and broader descriptive fold-return adoption belong to Sprint 17.73's separately bounded caller work.

#### Deliverables

- Add only abstract `PredecessorDigest`, hidden constructor, `mkPredecessorDigest` and total
  `predecessorDigestText` in Rooted. Reuse unchanged `requireDigest "completed response"` for exactly
  64 lowercase hexadecimal characters. The monomorphic Eq/Show scalar is inert DATA, not authority,
  with no parameter-role annotation, accepting raw replacement kernel or generic request-predecessor claim.
- Type only ReceiptRecorded's final completed-response commitment input; its existing pair checker
  equates that value to ReceiptConfirm's predecessor. Adopt only that builder and its existing branch
  in decodeUnsignedResponse, after raw decodeResponsePost/decodeResponseDigest validation and the already
  checked ordinal. Those two existing Rooted declarations are the owned set; other builders, opaque
  helpers, decoders, DATA, descriptive callbacks/folds/pairing and request predecessors stay unchanged.
- Construct the role only in Relay's existing receipt-recorded arm, from its existing decodeUtf8Lenient
  body interpretation, AFTER selected checkedOrdinal. Preserve wrapped-zero priority before malformed
  completion, all preceding checks/callback/IO order, generic fallback and all other raw ByteString bodies.
  Existing attached-session/path/nonce validation and receipt-publication/completion SHA provenance remain
  actual producer contracts; add no producer, arbitrary authority fixture or raw preflight adapter.
- Preserve all four fixed Rooted subjects, their exact names/complete clauses, all six prior scalar APIs,
  whole Handoff/Recovery a6/five bundles, Relay's 4292-byte transport/postOpenNonce/generic prefix and fallback,
  capability/path/raw-response controls, other production/Cabal/project bytes, private/public inventories
  and old labels. No digest/count/complement rebase or broader body interpretation occurs.
- Add the malformed/valid hex constructor/eliminator table. Adopt only the Receipt row of the six-builder
  DATA table with checkedPredecessor at the actual completed argument; raw completion body, ReceiptConfirm
  request, expected bytes and existing pair-relation refusal remain exact, as do the other five rows.
  Owned source controls pin exact typed input, raw-validation-before-wrap and ordinal-before-digest ordering.
  Retain all wire, crypto, refusal and preservation evidence without changing generic readers/matchers.
- Add `RawTextAsRootedPredecessorDigest.hs` and `RequestDigestAsRootedPredecessorDigest.hs` through the
  actual ReceiptRecorded kernel's final argument with every earlier coordinate correctly typed; matching
  positives change only that parameter. Reexport otherwise-unused abstract imports to keep identical
  imports used under -Werror. Add `CoerceRootedPredecessorDigest.hs`/`ForgeRootedPredecessorDigest.hs`
  from Text with plain PredecessorDigest(..) imports. Measure actual selected-five categories/complete
  per-diagnostic phrases before registration. All 636 old fixtures and all six current positives stay
  byte-identical; no fictitious two-position swap is added.
- Update only the declared architecture document for this seventh inert input scalar, exact completed-
  response role and format-versus-provenance/pairing distinction. Generic opaque reports/refusals, raw
  request predecessors, descriptive/Opened/request-builder APIs and authority contracts keep their scopes.

#### Validation

HandoffSpec checks empty/63/65/uppercase/nonhex refusals, exact64 elimination, current ReceiptRecorded/
ReceiptConfirm wire/codec/pairing and the unchanged other-family/crypto/preservation controls. CompileFailSpec
uses actual selected-five arguments for raw Text, wrong RequestDigest role, coercion and constructor access,
with matching positives and unchanged Main-only privacy. Existing positives, compiler resolver/runner,
complete per-block matcher and strict import grammar remain exact. Run actual focused HandoffSpec/public
compile-fail/indexed project-plan foundation/DocValidatorSpec then all four host static commands; record
actual scope/results. The phase's separate gate remains due at phase closure.

Dated 2026-11-02 pre-edit baseline at 15:07:22.442153 UTC captures 35 texts, 930 Haskell files and
636 fixtures outside the repository. Rooted is
`075487a7b7e376bb7a4399f742936b2ae72064cef7452df74f9a03ec369c09e8`; Relay is
`ccfa05c752c97e9bfe21bccead46022f72f4c16134a3a99eab74abbb04d00948`.
The Temp actual-100-argument SourceGuard/Aeson helper built before source/test edits at
15:07:49.664141 to 15:07:53.280638 UTC in 3.616502 seconds, exit0/empty stderr. Saved/current
measurement passed at 15:07:53.280658 to 15:07:54.266067 UTC in 0.985408 seconds, exit0/empty
stderr, with actual entries/serialized bytes and frozen source/metadata equal. Shape/role, request31,
response22 and shared20 retain 1351/16871/20240/4189 Aeson bytes and fixed respective digests
`2f669c249c2291c98b4ce57e0b307479b2be669834e823d60b7683f22b19ae42`,
`5460d05bf207b1fe47943a2eed3cd7c54ebfdaee39e29fc143316ee4c43c70ae`,
`48fbcb826f5bae7f727276a3950e05679bda7fd9892250e00dd634e1cbdd9b6f`, and
`50411bdbff15a847d7550bd78b189104ca05fadd593467a7039e237889a2cf11`.
Exact positive names/order and all complete clauses remain fixed; no fabricated expected rows are used.
Current caller review locates completed-response SHA production after successful receipt publication,
validated common coordinates before attachment and nonce decoding before receipt selection. Thus the
actual role construction retains prior common/nonce ordering; its own format predicate and ordinal-
before-digest ordering remain explicit, independently of that provenance. Implementation and actual compiler/focused/full results are recorded below.

Dated 2026-11-02 production freeze: exactly one PredecessorDigest, 23 changed nonempty / 26 physical
lines across Rooted (20/23) and Relay (3/3). Frozen SHA-256 values are
`f68eb9e940fa900e8be3f969b6dd42377cf13ee7f47d923c527ca0151674fc7d` and
`fd358c5b8a93ca779bff5259f1489cb1a67a696de0524c2d7bb2f5d4f055268f`.
Independent production/document reviews pass: only the two declared Rooted functions and selected Relay
receipt arm change, original validations remain raw-exact after elimination, ordinal precedes digest,
actual published SHA/common/nonce provenance and pair law stay separate from the format factory.
All four fixed subjects, six prior APIs and other production/Cabal/project bytes remain unchanged.
Native `cabal build all` from core passed at 15:12:31.593436 to 15:12:46.240420 UTC in
14.647074 seconds, parent 0/empty stderr, with exact frozen source/metadata.

Six actual selected-five probes use the unchanged measured 100 arguments. All declared outcomes pass
at 15:14:07.917216 to 15:14:08.713550 UTC:

| Actual source | Exit | Seconds | Named outcome |
|---|---:|---:|---|
| RootedPredecessorDigestTypedInput | 0 | 0.138361 | Exact typed positive, empty stderr |
| RootedPredecessorDigestDistinctRequestInput | 0 | 0.129884 | Exact typed positive, empty stderr |
| RawTextAsRootedPredecessorDigest.hs | 1 | 0.132653 | One GHC-83865 block: expected PredecessorDigest/actual Text at real Receipt argument7 |
| RequestDigestAsRootedPredecessorDigest.hs | 1 | 0.133026 | One GHC-83865 block: expected PredecessorDigest/actual RequestDigest at that argument |
| CoerceRootedPredecessorDigest.hs | 1 | 0.122610 | One complete GHC-18872 Text representation/hidden-constructor block |
| ForgeRootedPredecessorDigest.hs | 1 | 0.137650 | GHC-01928 illegal term-level PredecessorDigest use |

Both positives are exact current inline literals and differ only in their final parameter type; opaque
module reexports keep identical imports used. Constructor subjects request PredecessorDigest(..) and
reach intended failures without import errors/warnings. Each negative has one complete named block.
All 636 earlier fixtures and all six earlier positive literals remain byte-identical; no old API control
needs adoption. Actual probe source/compiler metadata hashes remain frozen. Measured subjects:

- RootedPredecessorDigestTypedInput: `12e50b273552b10898ae8cec155cdb0ace0b9761bba00a6fef3f7ff259bd8e0d`.
- RootedPredecessorDigestDistinctRequestInput: `334046b88710004f4281c985dba750a1312aa9de023ade8a79c2236a3cdf3321`.
- RawTextAsRootedPredecessorDigest.hs: `f74cc723262c549b994418c770168898e5c8007d6b97aaf88f7a135c5a84ecd7`.
- RequestDigestAsRootedPredecessorDigest.hs: `863bc6c32dbb680d3df9ce6db65875e27eaaa18b228ee2071959c57311e986ed`.
- CoerceRootedPredecessorDigest.hs: `6f8e4c9fefe44f4315b31307c053aa136bd4ab3c26ef7cd6e687f1b7ead3ec8f`.
- ForgeRootedPredecessorDigest.hs: `62c19e7120d2119f73210be7a1ae54a2c212a89d1098a558e6eda09c50f225e0`.

Final test sources are frozen at HandoffSpec `03862d7e6fbb2e9defa8c33d9acdd6705ba5c6c42f93e7f8a9db0620268fbdab`
and CompileFailSpec `2beba2e3c69174bbc0326d07c2025382f868c14cd4e17fc0f3f613a99736aa1a`.
Test compilation, focused and all-four results are recorded below.

Native test-component build passed at 15:16:12.284843 to 15:16:44.759009 UTC in
32.474363 seconds, parent 0/empty stderr, actual linked rts_thr and exact frozen source/metadata.
Final/reciprocal test audit passes at 113 changed nonempty / 121 physical lines: HandoffSpec (48/48),
CompileFailSpec (40/40), four new fixtures (25/33). All 192 old labels remain with one new case;
all 18 hashes and the entire fixed preservation-helper suffix remain byte-identical. Both recorded
complete-module reversals restore immutable baselines. All 636 old fixtures, all six prior positive
controls, 926 unrelated Haskell files and Cabal/projects remain exact. Only Receipt's actual completed
argument changes in the six-builder table; raw completion/ReceiptConfirm/expected pairing bytes and
the other five rows remain exact. Actual compiler bytes/diagnostics and the completed-response/pair-law
scope pass independent review. Actual focused and all-four results are recorded below.

The first focused-selector preflight at 15:18 UTC stopped before execution: its orchestration pattern
omitted receipt from the new scalar case's actual label and selected 50 rather than the required 51
checks. The external run pattern alone adopts the exact existing case name; no test/source fixture,
registration or expected selection count changes. No direct/full test result is claimed from that
catalogue-only attempt. Actual direct/full results are recorded below.

Dated 2026-11-02 final validation: all 51 direct checks passed at 15:20:18.567776 to
15:20:33.262070 UTC (14.51 reported / 14.694363 wall seconds), then all 1084 focused cases
passed at 15:20:33.464067 to 15:23:25.183425 UTC (171.62 / 171.720392 seconds).
Both parents exited 0 with empty stderr and exact source/compiler bytes. The corrected catalogue
selected the actual 51 labels before execution.

The root-owned source synchronization copied only the 11 declared files at 15:21:15.563474 to
15:21:15.696507 UTC (0.133018 seconds, exit0). Before gate launch, the root snapshot audit passed
1059 native/Linux files and the exact 934-Haskell-file directory set at 15:21:16.045944 to
15:21:16.764526 UTC (0.718565 seconds, exit0). Independent frozen-snapshot review passed at
15:25:35.745238 to 15:25:48.584690 UTC (12.839450 body / 18.048560 outer seconds).
All four host-static commands ran once against this unchanged retained Linux snapshot:

| Command and working directory | UTC start to end, 2026-11-02 | Command seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all --test-show-details=direct --test-options=--hide-successes | 15:24:28.077206 to 15:29:53.635418 | 325.560178 | All 3923 passed, 266.28 reported seconds; Cabal PASS, parent0 |
| demo/: cabal test all --test-show-details=direct --test-options=--hide-successes | 15:24:28.077276 to 15:29:52.264692 | 324.189379 | All 165 demo passed, 1.48 seconds; all 3923 core passed, 268.84 seconds; both Cabal PASS, parent0 |
| root/: poetry run python -m hostbootstrap.check_code | 15:24:28.080163 to 15:24:29.255890 | 1.175718 | Ruff/Black/mypy pass, parent0 |
| root/: poetry run python -m hostbootstrap.test_all | 15:24:28.086618 to 15:24:35.027408 | 6.940815 | 376 passed, 5.64 reported seconds; 100% statement/branch coverage, 1585 statements/460 branches, zero misses/partials; parent0 |

Every command's frozen-after check passes. Expected negative-fixture diagnostics on the Cabal
commands are retained in the harness captures; the actual aggregate suite and parent results above
are passing. Both raw Cabal captures report 26 host-row families, 62 supported/21 refusal completions
and root (1,0). The native compiler/direct/focused runs above additionally exercise the Windows gate host;
no live provider, realized host or non-baseline hardware result is claimed.

Independent final source audit passed at 15:30:35.705224 to 15:30:47.986724 UTC (12.281496 body /
17.379206 outer seconds), parent0: all 934 Haskell files digest
f100ddf75de67e7898a28915dd39ede2e74040f20a128b1ae357b1899ceb7bbd,
909 owned files digest 09e6d7b0126302cc502ce986450164621c62e8887549539791ace713938b15bf,
and 95 governed docs digest 92bdba435596d0ada905f1346efe91ee83a9b9426121c76ef4859c6cf9e8a932
match the gate snapshot. Exact module reversals, 926 unrelated old Haskell files, all 636 old fixtures
among 640 current fixtures, all six earlier positive literals, all 18 hashes/entire preservation-helper
suffix, four fixed Rooted subjects, whole Handoff/Recovery a6/Relay4292, non-receipt paths, public/private
inventories, Cabal/projects and compiler metadata pass. The actual compiled Phase1 digest remains
0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7
(query 0.187889 seconds, wrapper 0.510007 seconds, parent0). Final process/metadata audit at
15:30:52.183802 to 15:30:52.570166 UTC passed in 0.386369 seconds, parent0: original retained
container/start/init/two read-write mounts, unchanged four metadata subjects, PID1/PID7/audit only,
and no surviving gate processes. Source and governed prose stayed frozen through these audits.
The phase's own declared gate remains due after its remaining sprints.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T15:31:37.979608+00:00 to 2026-11-02T15:31:43.471302+00:00,
5.491709 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.50: Frame-child process trees end on Windows [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/ChildGroup.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
**Production budget**: at most 400 changed nonempty lines across the three declared production modules; one opaque ChildGroup contract
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Give each successfully acquired child-group bracket one scoped lifetime owner, independent of the
leader's exit status. On Windows it owns the exact kill-on-close Job Object assigned before the child
can start descendants. Returned outcomes, refusals, protocol failures, callback exceptions and
cancellation all release that job. Both real transports adopt the same private boundary; the
Transaction owner carries no conditional compilation. This is one ChildGroup contract and its
minimal three-module caller closure. Sprint 13.51 separately captures the POSIX group id and replaces
that row's leader-based grace.

#### Deliverables

- Add one abstract ChildGroup and a mask-protected shared launch bracket in Effect.ChildGroup.
  On Windows, use the pinned process library's use_process_jobs launch: its native implementation
  sets JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, creates the child suspended, assigns it and resumes it.
  Atomic modifyProcessHandle transfers the exact OpenExtHandle job into the scoped owner and leaves
  OpenHandle for leader polling/reaping, before any public polling or restored caller execution.
  There is no duplicate handle or registry. Standard process-library acquisition failures precede
  this acquired-group contract; no repair of that library's private failed-acquisition paths is claimed.
- End and close the owned job on every exit of that acquired bracket, including when the leader has
  already exited or been polled. Terminate the job, use bounded active-process observation for the
  group grace, and close its exact handle in finally. Keep all Windows primitives inside ChildGroup.
  Reuse existing process-internal operations where their pinned implementation meets that contract;
  use only a small locally verified Win32 query binding for bounded job-presence observation.
- Adopt that owner in both Transaction and Handoff.Process without changing route selection,
  executable/argv construction, protocol/relay behavior, bytes, deadlines or exception classification.
  Leader reaping and pipe cleanup retain their owners. On POSIX this sprint retains existing launch/
  signal/poll behavior; the captured-group and unconditional POSIX teardown change remains Sprint 13.51.
- Add real native Windows child/grandchild cases using the compiled core test binary itself,
  reporting actual process ids. Retain kernel process handles, prove descendants alive before release,
  then require signalled exit within the grace on return, exception, cancellation and leader-exits-first.
  Test-owned cleanup always releases native observations and ends any independently retained survivor.
  Add an actual frame-transaction integration through its existing entry and interpreter, with fixed
  test payloads; no production test branch, substitute executable or script is introduced.
- Keep the Windows observation cases compiled and registered on every gate host. Their POSIX branch
  asserts the declared unsupported native-observation row and its platform boundary, with conditional
  completion accounting; it never claims to have exercised Windows jobs on a POSIX gate host.
- Adopt only source assertions and effect launch-owner inventory entries whose actual ownership
  moves to ChildGroup. Retain existing case labels and unrelated guards, all Rooted/Handoff/Recovery/
  Relay fixed preservation subjects, all 640 fixtures, all current compiler positives, compiler
  selection/privacy contracts, Cabal/projects and unrelated source bytes.
- Update the declared architecture document and canonical lifetime paragraph with the acquired-job lifetime, early-leader-exit cleanup,
  both transport callers and the separate POSIX captured-group work.

#### Validation

Dated 2026-11-02 native Windows evidence exercises these actual HandoffSpec cases under
native Windows child groups:

- returning from the acquired group ends its live child and grandchild
- an ordinary callback exception ends the acquired child tree and is preserved
- ThreadKilled ends the acquired child tree and remains asynchronous cancellation
- reaping the leader first leaves its grandchild owned until bracket exit
- the actual frame transaction owns and ends its interpreter's native grandchild

Each supported case retains native process handles, proves liveness before the trigger, and proves
kernel-signalled exit before independent fixture cleanup. The early-leader case explicitly polls/reaps
the leader while its grandchild is still alive. The integration uses the actual frame entry and
transaction with a test-only interpreter extension for fixed DATA. POSIX cases assert the declared
unavailable native-observation instrumentation, execute a real ordinary frame control, and check the
source platform boundary; they claim no Windows runtime result.

The pre-edit baseline at 15:32:27.928016 UTC captures37 texts,934 Haskell files and640 fixtures.
Final production is one opaque ChildGroup contract,227 changed nonempty/238 physical lines across
ChildGroup157/168,Transaction32/32 and Handoff.Process38/38. Exact final SHA-256 values:

- ChildGroup: c201b0c8fe1f451dd138ea2a1303c79c4e71c752cab09ac5db56a6ce8343e26f
- Transaction: 272125748b9d8232756917d9a57e32993143d070903862e970a043080e34c2ca
- Handoff.Process: 21bc1da21d21be45913c9658a96b73fbc950d76a248f01615ab1a3fe2953475a

The complete header-backed CAPI query uses class1,48 accounting bytes and ActiveProcesses at byte40.
Its optional return-length argument is nullPtr typed Ptr CULong to match the SDK's LPDWORD.
An actual external native SDK compile with ghc -c -fforce-recomp -Wall -Werror -optc-Werror passed
at16:06:11.834062 to16:06:12.301479 UTC in0.467405 seconds, exit0/empty stdout and stderr.
The pinned process1.6.26.1 source confirms suspended assignment before resume and exactly two
OpenExtHandle fields, leader/job. Actual masked transfer and sole scoped finally-close are reviewed;
no repair of the library's unreturned failed-acquisition handles is claimed.

| Native Windows command/selection | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal build all |16:08:13.740969 to16:08:19.116639|5.375703|parent0,empty stderr,frozen production/metadata|
| core/: cabal build hostbootstrap-core:test:hostbootstrap-core-test |16:08:19.423748 to16:08:24.104519|4.680799|parent0,empty stderr,rts_thr,frozen source/metadata|
| five native cases plus five affected inventory checks |16:08:27.456979 to16:08:34.914688|7.457736|All10 passed,7.35 reported seconds,parent0/empty stderr|
| HandoffSpec/EffectSpec/public compile-fail/indexed project-plan foundation/DocValidatorSpec |16:08:35.125842 to16:11:51.160521|196.035859|All1134 passed,195.93 reported seconds,parent0/empty stderr|

The focused scope is the prior1084 cases plus EffectSpec's44,five native cases and one generated
CoverageManifest family check. Final source/compiler bytes remain exact throughout both selections.
Earlier catalogue-only selector attempts matched the manifest check too or selected none; neither
executed cases or changed expected counts/source. The initial broader run had1129 passing cases and
five source-inventory refusals for a split foreign-import header/shared binder. The complete CAPI
declaration fixes that shape with the strict reader unchanged. Its first Main build completed parent0
but emitted an incompatible-pointer warning; that build is not accepted as clean validation. The
measured CULong correction and final clean builds/results above replace that declaration. No warning
suppression, reader/matcher change, fixture change or dependency change occurs.

All four host-static commands and the separately required native Windows core command pass:

| Gate host and command | UTC start to end,2026-11-02 | Command seconds | Actual result |
|---|---|---:|---|
| Linux core/: cabal test all --test-show-details=direct --test-options=--hide-successes |16:09:25.155091 to16:14:05.321751|280.168350|All3929 passed,268.84 reported seconds,Cabal PASS,parent0|
| Linux demo/: cabal test all --test-show-details=direct --test-options=--hide-successes |16:09:25.155323 to16:14:38.760398|313.606972|All165 demo passed,1.56 seconds;All3929 core passed,271.09 seconds;both Cabal PASS,parent0|
| Linux root/: poetry run python -m hostbootstrap.check_code |16:09:25.155252 to16:09:25.958600|0.803334|Ruff/Black/mypy pass,parent0|
| Linux root/: poetry run python -m hostbootstrap.test_all |16:09:25.157381 to16:09:32.147214|6.989859|376 passed,5.83 reported seconds;100% statement/branch coverage,1585 statements/460 branches,zero misses/partials;parent0|
| Native Windows core/: cabal test all --test-show-details=direct --test-options=--hide-successes |16:12:20.438675 to16:18:59.078232|398.641971|All3929 passed,387.66 reported seconds,Cabal PASS,parent0|

All five frozen-after checks pass. Expected negative-fixture diagnostics remain in Cabal captures;
their aggregate suites and parents pass. The separate provider-live suite explicitly reports
Unsupported/not requested on all three Cabal runs; this is no realized-host or live-provider evidence.
Each full core suite accounts for27 conditional families and root(1,0). Native Windows reports
49 supported/39 refusal completions, including native-job(5,0); both Linux copies report62/26,
including native-job(0,5). Thus the five Windows cases execute inside the native core host-static gate.

Final tests are HandoffSpec64296db66d2f84a1d04033efd820e285991e19338040e7576df8a4ac7e2b5531,
Spec5baa0ea360eba3b075ee309e19f82eef4b76c6bac8ff4691c003033bd6b5e468,
EffectSpec645d574d2c6bab0d9abf618c223731208c68eb298fe3d2fd3b8dc21d94bb5d51 and
CoverageManifest6539d686fa83a73ec031a14c725aba540fbe9aea400faa735a0c9d1c7f280f70.
Their combined footprint is321 nonempty/348 physical lines(279/303,7/8,25/27,10/10).
Both docs use four reversible spans,42/42 lines: core-library SHA
47ed9052b55f14f47f584679bf369d16e47b82aa6a7a4bcc96dafd4e0bd55f81 and standards SHA
5caf98d73d5a3632f9ee56c76c7242e53b1d82f09026ffcd375f2b50c0415fc1.
Their finalizer wording distinguishes attempted termination/observation from unconditional finally-close.

The final11-file sync passes at16:09:03.677372 to16:09:03.781373 UTC in0.103985 seconds.
Root native/Linux equality passes1059 files and the exact934-Haskell directory set at
16:09:04.113409 to16:09:04.366903 UTC in0.253476 seconds,parent0.
Independent initial audit passes at16:13:28.301541 to16:13:41.341242 UTC in
13.039699 body/18.598786 outer seconds. Independent final source audit passes at
16:21:05.709379 to16:21:17.528345 UTC in11.818973 body/16.633400 outer seconds,parent0.
Gate-snapshot digests remain exact through those audits: all934 Haskell files
7be0b20980532d3e10a8bdc2e98ab9d14a368bf701e986ec68a1f5603d58fba4,
909 owned files c1db98f35d714ad0f5fa987cda942ee23a4e76703383b126362bafa8221cba4c,
95 docs a6f2ba4d29672ca228de2f5f18d110e012ea3b4beeec4f2cb3cce42abf03419f.
All seven complete baseline reversals,927 unrelated Haskell files,whole CompileFailSpec/eight positive
controls/all640 fixtures,193 old HandoffSpec labels,18 hashes/entire preservation-helper suffix,
four fixed Rooted subjects,whole Handoff/Recovery a6/Relay/capability/path/codecs/readers/raw-response,
57 relocated homes/109 path controls,Main104/selected-five/97 pins,Cabal/projects/four metadata subjects
and four doc spans pass. Strict import/binder grammar,compiler selection,launch detector,group-owner
guard and all26 earlier conditional rows remain exact.

The actual compiled Phase1 digest is still
0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7;
the query passes in0.184621 seconds(wrapper0.484124 seconds,parent0)at16:21:05.594926 to
16:21:06.118357 UTC. Final Linux process/metadata audit at16:22:19.347302 to16:22:19.720922 UTC
passes in0.373624 seconds,parent0: original retained container/start/init/two read-write mounts,
PID1/PID7/audit only. Native Windows process audit at16:22:19.331468 to16:22:19.406436 UTC
passes in0.071007 seconds,parent0,with no relevant core/demo test,GHC or Cabal survivors.
Source and governed prose stay frozen through all required gates and final audits.
The phase's separate declared gate remains due after its remaining sprints.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T16:24:35.172277+00:00 to 2026-11-02T16:24:40.643834+00:00,
5.471575 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.51: Child-group teardown follows the captured process group [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/ChildGroup.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Production budget**: at most 400 changed nonempty lines across the three declared production modules; refinement of the existing ChildGroup contract
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Retain a POSIX group's identity for the acquired ChildGroup lifetime, independent of a polled or
already-exited leader. The scoped owner and both transports end the same captured group, including
descendants which ignore TERM. This refines the existing owner rather than adding another type or
caller-supplied teardown policy. The Windows acquired-job row stays byte-identical.

#### Deliverables

- Make the POSIX shared launch create its own process group before child execution. Capture getPid
  exactly once immediately after acquisition, before any getProcessExitCode, and retain the resulting
  ProcessGroupID in the opaque ChildGroup. A missing acquired identity is a refusal, not a silently
  unowned group. No signal or presence observation rediscovers identity through a reaped leader.
- Signal and poll only that captured group. The bounded grace probes signalProcessGroup nullSignal;
  only ESRCH/isDoesNotExistError means absent. Other native errors remain errors. Keep explicit leader
  polling/reaping separate; completion requires both an exited leader and an absent group.
- Run acquired-group cleanup on every bracket exit, including when an inner teardown raises.
  Always ask the captured group to stop, wait the fixed grace, then kill a remaining group and observe
  its bounded exit. The outer owner supplies the cleanup fallback, while both transport owners still
  reap their leader and close pipes. Transaction never skips group cleanup because its leader exited.
  Preserve route/argv/codec/relay behavior and existing exception classification.
- Add two real POSIX EffectSpec cases using the existing compiled-binary effect probe dispatcher:
  a leader exits after publishing a TERM-ignoring descendant, and a leader itself ignores TERM.
  Prove actual pid/group liveness before release; explicitly reap the first leader while its descendant
  remains alive, then require the group and descendant gone on bracket return. Retain independent
  test-owned cleanup and bounds exceeding the fixed ten-second grace. No script, substitute executable,
  invented pid, private process registry or custom harness reaper is introduced.
- Keep both cases compiled/registered on Windows, asserting the existing unavailable POSIX observation
  instrumentation. Add one exact two-case conditional family with the existing POSIX support boolean.
  Keep all five native Windows job cases and their current source controls unchanged.
- Adopt only the existing HandoffSpec POSIX source assertion for the new captured identity/presence
  contract. Preserve all earlier case labels, fixtures/current compiler positives, strict reader/matcher/
  launch-owner rules, Windows raw branch, fixed Rooted/Handoff/Recovery/Relay subjects, Cabal/projects,
  private/public inventories and unrelated source bytes.
- Update the two declared docs from leader-based POSIX debt to the acquired captured-group contract,
  with truthful bounded cleanup/error semantics and unchanged Windows lifetime wording.

#### Validation

Dated 2026-11-02 EffectSpec cases under scoped POSIX child groups execute on the retained Linux gate:

- an explicitly reaped leader leaves its descendant owned until scoped exit
- a TERM-ignoring leader and descendant are gone when the scope returns

The compiled test binary's existing dispatcher starts the real probe. Ignore is installed before fork,
two complete PID words are newline-published,and a release barrier permits initial leader/descendant/
actual-PGID liveness checks. The first case explicitly reaps the leader while its descendant and group
remain alive despite TERM. Both require PID and group absence after the actual scoped bracket returns,
before independent fixture cleanup. The30-second action bound exceeds the fixed ten-second grace.
On Windows,both compiled cases assert the existing unavailable POSIX observation instrumentation;
all five existing native Windows job cases continue to execute and pass.

The pre-edit baseline at16:25:19.579027 UTC captures37 texts,934 Haskell files and640 fixtures.
Final production is96 changed nonempty/97 physical lines across ChildGroup78/79,Transaction10/10
and Handoff.Process8/8,refining the existing contract with no new type/API. Exact SHA-256 values:

- ChildGroup:2d6d9c1ae8e99fff3252a1e47d9164a1a72ece70250c02b01d7728cdc4b489c6
- Transaction:5d835e311a85fac7b3da48947dfe0ba6603f9be982f42d67b4e2d1bd893b9bd2
- Handoff.Process:d662f639ca94441ef8898d05cc451ebf5641428fe360e5be1f979bc2f0a60012

Independent source review and complete baseline reversals pass: all9 Windows true CPP arms,
existing API/close helper/timeouts,201 other production files,Cabal/projects,whole compiler spec/
eight positives/all640 fixtures remain exact. Route/process shapes,protocol/relay code and exception
classification remain unchanged. Captured identity is acquired once before polling/restored execution;
TERM/KILL/nullSignal all use it. Only ESRCH means absent. Outer finally cleanup retains bounded
kill/observation fallback and reports a remaining group instead of silently accepting it.

| Build or selection | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core/:cabal build all |16:34:54.577404 to16:35:02.271778|7.694420|parent0,empty stderr,frozen production/metadata|
| Linux core/:cabal build all |16:37:07.774187 to16:37:16.190177|8.416006|parent0,empty stderr,frozen production/metadata|
| Native Windows core/:cabal build hostbootstrap-core:test:hostbootstrap-core-test |16:41:57.306317 to16:42:05.133676|7.827404|parent0,empty stderr,rts_thr,frozen source/metadata|
| Native Windows five job cases,two POSIX unavailable rows,five inventory checks,existing process-owner source case |16:42:20.743329 to16:42:28.926254|8.182955|All13 passed,8.06 reported seconds,parent0/empty stderr|
| Native Windows HandoffSpec/EffectSpec/public compile-fail/indexed project-plan foundation/DocValidatorSpec |16:42:29.138642 to16:45:40.860539|191.723052|All1137 passed,191.62 reported seconds,parent0/empty stderr|
| Linux core/:two scoped POSIX cases through cabal test all with an exact test-option pattern |16:43:34.883430 to16:44:33.446685|58.563594|All2 passed,20.52 reported seconds,Cabal PASS,parent0/empty stderr|

The native focused scope is the preceding1134 cases plus two POSIX cases and their generated
CoverageManifest family check. All final frozen-after checks pass. The first native test build at
16:39:12.271393 to16:39:40.584868 UTC(28.313646 seconds,parent1)reported GHC-63397 under -Werror:
a newly imported cwd record label shadowed the existing repoRoot local variable. Only the new field
use/import is qualified as Process.cwd; exact two-span reversal restores the first test freeze and
the old repoRoot body remains byte-identical. No warning suppression or existing-helper rewrite occurs.

All four host-static commands pass against the final retained Linux snapshot:

| Command and working directory | UTC start to end,2026-11-02 | Command seconds | Actual result |
|---|---|---:|---|
| core/:cabal test all --test-show-details=direct --test-options=--hide-successes |16:45:20.705799 to16:50:06.335585|285.631507|All3932 passed,280.65 reported seconds,Cabal PASS,parent0|
| demo/:cabal test all --test-show-details=direct --test-options=--hide-successes |16:45:20.705928 to16:50:42.091025|321.387042|All165 demo passed,1.44 seconds;All3932 core passed,279.07 seconds;both Cabal PASS,parent0|
| root/:poetry run python -m hostbootstrap.check_code |16:45:20.712962 to16:45:21.487653|0.774677|Ruff/Black/mypy pass,parent0|
| root/:poetry run python -m hostbootstrap.test_all |16:45:20.743973 to16:45:27.720486|6.976539|376 passed,5.92 reported seconds;100% statement/branch coverage,1585 statements/460 branches,zero misses/partials;parent0|

Expected negative-fixture diagnostics remain in the Cabal captures; aggregate suites and parents pass.
The separate provider-live suite explicitly reports Unsupported/not requested; this is no realized-host
or live-provider result. Both full core captures account for28 conditional families,64 supported/
26 refusal completions,root(1,0),scoped-POSIX(2,0)and native-Windows-job(0,5).

Final test SHA-256 values are EffectSpec761b7b854085d0a1498cbde05d26a99e1bc687e4e9579a1b68b2b99929521da6,
HandoffSpec689500d3f570c9759065449db20f24948cbdf3cd0d2954ccb1787b679e9309f6 and
CoverageManifestf00ebc9c27e3288205d565cdf5125e0bb4de44d32bca6f9471ade0f1d10ff764.
Their combined footprint is175 nonempty/181 physical lines(138/144,28/28,9/9).
Docs use only POSIX lifetime/debt spans,20/20 lines: core-library SHA
7aee61bccc6f825df671598aec5623e9fef48289f11d7877d904b98decc0277c and standards SHA
71180a0b7a61551c4bc0d05bc6e3f1b302ee500fc5bddcad7f45e048e332f380.
Windows source checks,all five runtime cases and lifetime wording remain raw-exact.

The final10-file sync passes at16:43:19.726569 to16:43:19.830386 UTC in0.103803 seconds.
Root native/Linux equality passes1059 files and the exact934-Haskell directory set at
16:43:20.186444 to16:43:20.439549 UTC in0.253089 seconds,parent0.
The first independent audit stopped on external rollback metadata assumptions(string versus line-array
spans,adjacent spans,and conditional-label indexing); the initial9.666145-second exit1 capture is
retained. Correcting only that external reader produces final audit PASS after all gates,without
source changes or gate reruns. Its wrapper runs at16:55:30.834461 to16:55:48.713570 UTC,
17.879224 wrapper/12.555201 audit seconds,exit0. Gate-snapshot digests stay exact:
all934 Haskell files ab143df658c6a06f8045af7015f47c8af13f0f274e9f762d85efc8eb4cef2d96,
909 owned files9fe02b6f1ea3b5d67e9bfe1c6cbc43d9f702ea15e9400542f45afda4734d1bab,
95 docs bbb267ff9f6519e91701b23e0c80213461bbece0b21d7249cc0c2891a387a7d4.
All six module/two doc complete reversals,928 unrelated Haskell files,640 fixtures/whole compiler spec/
eight positives,193 old Handoff and36 old Effect labels,18 hashes/entire preservation-helper suffix,
27 old conditional rows,four fixed Rooted subjects,whole Handoff/Recovery a6/Relay4292/capability/path/
codecs/readers/raw-response,57 relocated homes/109 paths,Main104/selected-five/97 pins,
Cabal/projects/four metadata subjects pass.

The actual compiled Phase1 digest remains
0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7.
The query passes at16:54:15.851686 to16:54:16.303961 UTC in0.183987 query/0.414916 wrapper
seconds,parent0/empty stderr. Linux process/metadata audit at16:54:43.547151 to16:54:43.928405 UTC
passes in0.381260 seconds,parent0: original retained container/start/init/two read-write mounts,idle.
Native process audit at16:54:43.486548 to16:54:43.549513 UTC passes in0.059747 seconds,parent0,
with no relevant test,GHC or Cabal survivors. Source and governed prose stay frozen through all gates
and final audits. The phase's separate declared gate remains due after its remaining sprints.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T16:57:27.872314+00:00 to 2026-11-02T16:57:35.204288+00:00,
7.331998 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.52: Activation manifests have one checked input producer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Add one plain ActivationManifestInput DATA contract and the real activationManifest producer in
one production module. Existing manifest representation,signing,decoding and verifier APIs remain
unchanged here. Sprint13.53 owns the actual demo caller;13.54 owns the bounded sealing/decoder closure.

#### Deliverables

- Define ActivationManifestInput with distinct plain input labels for the twelve existing coordinates,
  including the already opaque ActivationSecretDigest and ordered effect list. This unchecked input
  is DATA and carries no signing/effect authority.
- Construct the candidate only inside activationManifest,run unchanged validateManifest,and return
  only its success. Preserve exact ten nonempty-text and empty/duplicate-effect predicates and details.
- Accept empty effect lists and descriptive nonempty text,including non-hex digest-shaped fields.
  Add no new format,path,instance,provenance or blanket secret-free rule.
- Add real producer successes and all twelve malformed-field/effect refusals in ActivationSpec.
  Preserve every earlier signer/verifier/decoder test and independent literal wire/signature vector.
- Add only the owned input/producer exports and exact reviewed Activation export-pin adoption.
  Preserve all seven verified-activation nominal identities,fixtures and unrelated production bytes.
- Document plain input versus checked output; do not hide the legacy constructor,change decoding,
  introduce role wrappers or adopt the demo in this step.

#### Validation

Dated2026-11-02 ActivationSpec adds exactly three checked manifest input cases:

- the checked producer retains the independent manifest and signature vectors
- the checked producer refuses each malformed required field and effect row
- the checked producer accepts empty and ordered effects and descriptive digest text

The actual factory output equals the existing base manifest and independent literal wire. The genuine
seed97 broker signature equals the existing OpenSSL literal. The refusal table covers exactly ten
nonempty Text fields in the existing order,then empty/duplicate effect entries,with exact details.
Empty effect lists,ordered distinct effects and five non-hex descriptive digest coordinates remain
admitted and retain values/order. All40 earlier cases,tables,helpers and literal vectors stay raw-exact.

Before source edits,the baseline at17:14:08.405497 UTC captures39 texts,934 Haskell files and640
fixtures,including the complete old Activation source and its validation/render/decode/sign/verify/
seven-axis declarations. The plan recut precedes implementation:52-57 activation,58-67 build roles,
68-70 single Digest owners,71 sibling install. Native DocValidatorSpec passed all17 at
17:13:02.951052 to17:13:09.615939 UTC(6.57 reported/6.664907 wall seconds,parent0/empty stderr),
with frozen phase/index/ledger bytes and scoped diffcheck0.

Final production is one plain ActivationManifestInput type and real producer:42 nonempty/45 physical
added lines in one module,Activation SHA
d50807759b46b0f7d9c257892c6778a0e6f60a6027115c9d456b943b06ac8994.
Only two insertions add the two exports and input/factory block. Their exact reversal restores the
entire immutable93346de2 baseline,every existing declaration and byte. All twelve coordinates map
directly; unchanged validateManifest runs before returning that candidate. No imports,dependencies,
IO,additional format/provenance rule or legacy API change occurs. Existing constructor,decoder,
signing and verifier behavior stay unchanged in this sprint.

| Native Windows command/selection | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
| core/:cabal build all |17:17:08.024757 to17:17:22.856076|14.831411|parent0,empty stderr,frozen production/metadata|
| core/:cabal build hostbootstrap-core:test:hostbootstrap-core-test |17:19:20.244084 to17:20:49.561497|89.317972|parent0,empty stderr,rts_thr,frozen source/metadata|
| three new producer cases plus five inventory checks |17:21:40.420077 to17:21:48.139183|7.719135|All8 passed,7.61 reported seconds,parent0/empty stderr|
| ActivationSpec/HandoffSpec/EffectSpec/public compile-fail/indexed project-plan foundation/DocValidatorSpec |17:21:48.361732 to17:25:06.715637|198.355138|All1180 passed,198.23 reported seconds,parent0/empty stderr|

The focused scope is the previous1137 plus all43 ActivationSpec cases. Final test sources are
ActivationSpececd2eb15afd6d58ceaa246d844105dbbe4762ce77be6a148d74997c9857c990a and
SealedExportInventory15794601a0ae7eb5fb55a27fb5a13a934e43a3e570f2b7ffa0a8bca95a1f650d,
66 nonempty/68 physical lines(65/67+1/1). Both full baseline reversals pass. The actual export item
list/pin gains only ActivationManifestInput(..) and activationManifest; all97 pins remain and the other
96 are byte-identical. No generic reader/compiler matcher or current fixture changes.

The one declared doc insertion is15/19 lines,unrepresentable_state SHA
d5e75306e1b6c3b3680a3768e8f5150e05534b11b7f858772163b68031cd43ef.
Every earlier doc byte is retained. It limits validation to producer success and makes no sealed-
manifest or validated-decoder claim before the later declared boundary.

All four host-static commands pass on the retained Linux snapshot:

| Command and working directory | UTC start to end,2026-11-02 | Command seconds | Actual result |
|---|---|---:|---|
| core/:cabal test all --test-show-details=direct --test-options=--hide-successes |17:23:32.439763 to17:30:31.368791|418.931649|All3935 passed,293.35 reported seconds,Cabal PASS,parent0|
| demo/:cabal test all --test-show-details=direct --test-options=--hide-successes |17:23:32.439868 to17:30:24.698334|412.261045|All165 demo passed,1.51 seconds;All3935 core passed,291.75 seconds;both Cabal PASS,parent0|
| root/:poetry run python -m hostbootstrap.check_code |17:23:32.440019 to17:23:33.297864|0.857835|Ruff/Black/mypy pass,parent0|
| root/:poetry run python -m hostbootstrap.test_all |17:23:32.449282 to17:23:39.314335|6.865080|376 passed,5.81 reported seconds;100% statement/branch coverage,1585 statements/460 branches,zero misses/partials;parent0|

All frozen-after checks pass. Expected negative-fixture diagnostics remain in the Cabal captures;
their aggregate suites and parents pass. The separate provider-live suite explicitly reports
Unsupported/not requested; no live-provider/realized-host result is claimed. Both full core captures
account for28 families,64 supported/26 refusal completions,root(1,0),POSIX(2,0),Windows jobs(0,5).

Final7-file sync passes at17:22:59.726641 to17:22:59.814609 UTC in0.087953 seconds.
Root native/Linux equality passes1059 files and exact934 Haskell paths at17:23:00.179227 to
17:23:00.442934 UTC in0.263691 seconds,parent0.
Independent initial audit passes at17:26:21.022739 to17:26:39.615674 UTC in18.593053 wrapper/
18.516504 audit seconds. Final postgate source audit passes at17:31:49.777444 to17:32:07.716528 UTC
in17.939199 wrapper/17.861482 audit seconds,parent0,without helper failures/retries.
The held gate snapshot remains exact: all934 Haskell files
704b9949f35fd61085e78f00b6e3afdf8d81baefeb5270fc6107af22c4ec97ba,
909 owned files bf8b9df0aced12e1734b582b44fc772ec10325df362cf04d1487599053fb997f,
95 docs d1d75c5f907ad812dcc9d2f4d38f332a940075e3e054401d909eb41c902e3367.
All three module/one doc full reversals,931 unrelated Haskell files,640 fixtures/whole compiler spec/
eight positives,all old Activation behavior/seven nominal axes,Rooted fixed subjects,whole Handoff/
Recovery a6/Relay4292/capability/path/response/readers,18 hashes/helper suffix/193 Handoff labels,
109 paths/57 relocated homes/23 metadata snapshots,Main104/selected-five/Cabal/projects/HEAD pass.

The actual compiled Phase1 digest remains
0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7;
query17:31:49.731529 to17:31:50.227413 UTC passes in0.198028 GHC/0.455958 wrapper seconds,
parent0/empty stderr. Linux process/metadata audit17:32:04.642361 to17:32:05.015906 UTC passes
in0.373552 seconds,parent0: original retained StartedAt/init/two read-write mounts,idle/four metadata
subjects exact. Native process audit17:32:04.607600 to17:32:04.679888 UTC passes in0.068733
seconds,parent0,no relevant test/GHC/Cabal survivors. Source and governed prose remain frozen through
all required gates and final audits. The phase's separate gate remains due after its remaining sprints.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T17:34:44.395421+00:00 to 2026-11-02T17:34:49.967892+00:00,
5.572489 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.53: The demo constructs activation manifests through the checked producer [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Adopt the real producer at the sole external production manifest construction site. This is one
caller adoption and no library representation or verifier change.

#### Deliverables

- Use ActivationManifestInput and activationManifest at the actual demo construction boundary.
  Propagate refusal through the existing command result before signing/launch; no error,fromRight,
  default candidate or raw compatibility producer.
- Remove its now-unused constructor-bearing manifest import; import only ActivationManifestInput(..)
  and activationManifest alongside the six existing used functions. No manifest type/getter is used
  after adoption,so do not add an unused abstract type or getter import.
- Preserve all field values/order,secret measurement,revision,broker route and canonical bytes.
  Adopt only actual demo controls; keep core/compiler/privacy controls unchanged.

#### Validation

Dated2026-11-02 CommandsSpec adds two checked activation DATA cases. The actual private For source
slice holds the complete contiguous12-expression record/order,single factory,forced Either/die before
render/sign/install,and no raw fallback. Genuine finalized registry/config web and daemon DATA
exercises public factory success/roundtrip and exact empty-rollout refusal. This is DATA plus source-
join proof,not private command runtime execution: no StepExecution forgery,sidecar seam or copied lexer.
Earlier caller daemon-stop/binary-install/measurement and preexisting execution order remain unchanged.

The baseline at17:35:57.504812 UTC captures41 texts,934 Haskell files and640 fixtures; unchanged
demo Cabal is added at17:36:36.659066 UTC,42 texts total,af23af0f48f91cc1f474f5e861266d91f9ef25c675d117f7723013c7a45a1ebd.
Production Commands6e6dbd3a155fd8285575e3682b7b9d56099e6e63bf5327f31e3b2997a120be7a is37/37
changed lines in one module,no new type. Full reversal and all twelve expressions/order pass.
SIX old Activation functions remain exact(import totals7 to8); correcting the external seven-functions
assertion changes no source. All role/key/measurement/sign/install/caller bodies remain raw-exact.
CommandsSpec90003380ec4017f332f9411c6d6d59d15d171d0a816d124bc34b72a0d406dedc is118/119 lines;
eleven spans restore its whole baseline. All80 old literal labels/165 cases/helpers stay exact.
Doc8183639b6877c102a04064c0ebc04ea5e62c1ba2ecba836a903bea01cd2ab27b adds only6/7 lines.

| Native Windows build/selection | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
| demo/:cabal build all |17:38:24.101056 to17:39:53.677279|89.576785|parent0,frozen production/metadata;only Cabal index-age advisory,no GHC diagnostic|
| demo/:cabal build hostbootstrap-demo:test:hostbootstrap-demo-test |17:42:19.390238 to17:42:39.938929|20.548818|parent0,empty stderr,rts_thr,frozen source/metadata|
| two new DATA/source cases |17:44:21.489482 to17:44:21.624070|0.134573|All2 passed,0.11 reported seconds,parent0/empty stderr|
| complete native demo suite |17:44:21.764680 to17:44:26.942732|5.178067|All167 passed,5.15 reported seconds,parent0,frozen source/binary/plan|

The initial runner stopped before catalogue/execution because the optional plan-reported demo
build-info path is absent. The corrected runner explicitly freezes existing demo/cache/plan.json plus
actual binary and claims no missing artifact. Captured old host-teardown refusal diagnostics are from
existing negative tests catching ExitFailure1. No relevant processes survive the completed suite.

| Host-static command on retained Linux | UTC start to end,2026-11-02 | Command seconds | Actual result |
|---|---|---:|---|
| core/:cabal test all --test-show-details=direct --test-options=--hide-successes |17:48:03.779356 to17:53:16.847605|313.070204|All3935 passed,307.58 reported seconds,Cabal PASS,parent0|
| demo/:cabal test all --test-show-details=direct --test-options=--hide-successes |17:48:03.779219 to17:53:17.087335|313.310074|All167 demo passed,1.59 seconds;All3935 core passed,308.75 seconds;both Cabal PASS,parent0|
| root/:poetry run python -m hostbootstrap.check_code |17:48:03.778989 to17:48:04.651720|0.872714|Ruff/Black/mypy pass,parent0|
| root/:poetry run python -m hostbootstrap.test_all |17:48:03.793627 to17:48:10.970116|7.176516|376 passed,6.01 reported seconds;100% coverage,1585 statements/460 branches,zero misses/partials;parent0|

Every frozen-after check passes. Expected negative-fixture stderr is retained; actual suites/parents
pass. Provider-live explicitly reports Unsupported/not requested,no live claim. Both core captures
account for28 families,64 supported/26 refusals,root(1,0),POSIX(2,0),Windows jobs(0,5).
Final5-file sync passes17:47:25.221280 to17:47:25.317556 UTC in0.096255 seconds.
Root equality passes1060 files/exact934 Haskell paths17:47:25.712197 to17:47:25.989065 UTC in
0.276851 seconds,parent0; extra metadata is the positively captured unchanged demo Cabal file.
Independent initial audit17:51:29.809914 to17:51:49.136132 UTC passes in19.326346 wrapper/
19.254226 body seconds. Final postgate source audit17:59:11.386031 to17:59:36.504421 UTC passes
in25.118553 wrapper/25.036081 body seconds,parent0,first run. Held snapshot digests match:
all934940c0223e0fcb102c1f2cbe956691ac6edaf406a427b5784ae71736198932b0c,
unchanged core909bf8b9df0aced12e1734b582b44fc772ec10325df362cf04d1487599053fb997f,
docs951721872c19fef21e4e0fb8ff53618a8084b15e40aaaf4a96a758df0f286e811d.
Both demo modules/one doc completely reverse; all932 other Haskell files,entire core,ActivationSpec43,
compiler spec/eight positives/640 fixtures/97 pins,Rooted/Handoff/Recovery a6/Relay4292/capability/
path/response/readers,18 hashes/helper suffix,57 homes/109 paths,Main104/selected-five,core metadata,
demo Cabal/actual native plan+binary and HEAD pass.

Compiled Phase1 digest remains0d111e033fc7e7ed6ed0161f4021889092eb9fecb68c1ff73ee8d08badd905b7;
query17:59:11.347649 to17:59:11.865188 UTC passes in0.222822 GHC/0.478187 wrapper seconds,0/
empty stderr. Linux process/metadata17:59:27.082350 to17:59:27.491403 UTC passes in0.409057
seconds,0:original StartedAt/init/two RW mounts,idle/four metadata exact. Native process audit
17:59:27.013472 to17:59:27.077496 UTC passes in0.060578 seconds,0:no test/GHC/Cabal survivors.
Source and prose remain frozen through gates/final audits. The phase's own gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T18:05:36.671564+00:00 to 2026-11-02T18:05:42.949637+00:00,
6.278091 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.54: Activation manifests are sealed behind checked construction and decoding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Seal the existing manifest after its demo caller adopted the producer. Activation,Service and
Command.LifecycleEntry are the entire three-module production closure.

#### Deliverables

- Hide the constructor,rename private record labels and expose ordinary total getters under the
  existing public names. Block record updates; preserve existing Show and canonical wire/signatures.
- Preserve the decoder's actual sequence: outer framing/UTF-8 in order; secret-format at field8
  before later fields; secret-channel outer text before inner effect parsing; inner effects before
  trailing-byte refusal; semantic producer validation only after those checks. Every successful opaque
  decode uses the real producer; no raw decoder/kernel or bypass.
- Adopt only Service and Command.LifecycleEntry imports/getters; the demo's import is already ready.
- Own new admission precedence explicitly: Service selects the complete SELECTED decoder result
  before RECEIVED. Selected structural/semantic failure wins,then received; only two valid values
  reach unchanged ordered verifier comparisons. Do not claim the old late-invalid distinction.
- Replace unconstructible invalid-record observations with exact producer/decoder refusal and raw
  wire tables. Preserve valid vectors,policy/store binding,ordered mismatches and seven nominal axes.
- Measure constructor-requesting and genuine record-update negatives with real producer positives.
  Adopt only owned Activation export/fixture/doc changes; keep generic compiler readers exact.

- Preserve measured Show output at precedences0/10/11 and nested Maybe/list,escaped text/effects
  and redacted SecretDigest. Pin the actual pre-edit literals and retain derived WHNF forcing.

#### Validation

ActivationSpec covers producer/decoder refusals,framing priority,selected-before-received Service
admission and unchanged valid wire/signature/mismatch vectors. ConstructActivationManifest.hs and
a real record-update subject fail for their named reasons. CLISpec/HandoffSpec use genuine producers.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 pre-edit baseline at18:06:14.324736 UTC captures46 texts,934 Haskell files and640
fixtures. Root's actual unchanged100-argument GHC context proves both current holes compile before
any sealing edit: ConstructActivationManifest.hs(cb083c8869d64db011e58a7995140abde7855ad6bfc184dd564cb612bc568eb4)
at18:07:25.205244 to18:07:25.765878 UTC in0.560635 seconds,and
UpdateActivationManifest.hs(2b90323b2a8ebdc75adeecffb393d543c9cc7459ec794a60c4a99a85ed9c43bb)
at18:07:25.765935 to18:07:25.988008 UTC in0.222085 seconds,both0/empty stderr.
The constructor witness requests ActivationManifest(..),takes an opaque SecretDigest and uses lawful
positional fields; the update witness takes Manifest/Text and explicitly imports manifestRevision.
The public producer-based Show witness compiles18:07:25.988071 to18:07:31.020285 UTC in5.032257
seconds,0/empty stderr,and executes18:07:31.020306 to18:07:31.073818 UTC in0.053524 seconds,
0/empty stderr. Actual JSON literals capture precedences0/10/11,Maybe/list,escaped text/effect order
and existing secret redaction. All46 source/metadata subjects remain frozen; no fabricated expected
Show or compiler diagnostic is recorded.

Dated2026-11-02 implementation freezes220 changed nonempty/235 physical production lines across
Activation,Service and Command.LifecycleEntry; no new type or Cabal edge. The native Windows
GHC9.12.4/Cabal3.16.1.0 main build passes18:11:56.178081 to18:12:17.165007 UTC in20.987057
seconds,0/empty stderr. The producer is the sole constructor; all twelve public accessors are ordinary
functions over renamed private labels. The structural decoder prefix,canonical renderer,signing and
seven-axis verifier remain byte-exact; Service's six file loads remain before decoding and its successful
verification body changes only layout.

The same pre-edit constructor/update subjects fail after sealing at18:15:56.957963 to18:15:57.161784
UTC in0.203819 seconds(GHC-01928,illegal term-level ActivationManifest),and18:15:57.161837
to18:15:57.345833 UTC in0.184007 seconds(GHC-22385,manifestRevision is not a record field).
The public producer/all-twelve-getter positive(b2b6a5886612e4efb457bb9c7e09865ea80b52beafb0312ff93dadb8023aa74e)
passes18:15:57.345861 to18:15:57.556301 UTC in0.210451 seconds,0/empty stderr.
The identical Show witness compiles18:15:57.556362 to18:15:59.533754 UTC in1.977414 seconds
and executes18:15:59.533776 to18:15:59.593673 UTC in0.059908 seconds,both0/empty stderr:
all five measured JSON literals equal the pre-edit vectors. Production/compiler metadata is frozen
through these controls.

The native test build passes18:19:54.301759 to18:21:39.622121 UTC in105.321002 seconds,
0/empty stderr,actual threaded RTS. Six direct sealed-admission/constructor/update/public-producer
controls pass18:21:59.470433 to18:22:00.760754 UTC,1.16 reported/1.290304 wall seconds.
The first native affected-spec run selects487 cases and exits1 at18:23:38.953227 UTC after97.904489
wall seconds:486 behavior cases pass,but DocValidatorSpec refuses the new ActivationSpec provenance
comment's bare sprint number. The initial Linux core and demo commands likewise exit1 only for that
same governed-comment violation:3939 of3940 core cases pass(336.23 and337.61 reported seconds);
all167 demo cases pass(2.11 seconds). Their frozen-snapshot runs are18:20:30.545814 to18:28:40.419985
UTC,489.877138 wall seconds(core),and18:20:30.545920 to18:28:35.720078 UTC,485.177101 wall
seconds(demo). Python check_code passes in0.984342 seconds and376 Python tests pass in6.05
reported/7.313632 wall seconds,100% coverage(1585 statements,460 branches,zero missed/partial).
A one-comment correction removes the bare sprint reference; every assertion and behavioral byte remains
unchanged. The final measurements below establish closure.

The corrected native test rebuild passes18:29:15.793275 to18:29:25.033395 UTC in9.240174
seconds,0/empty stderr,rts_thr. Final native DocValidatorSpec passes17 cases18:29:34.930728
to18:29:40.750277 UTC,5.74 reported/5.819564 wall seconds,0/empty stderr. This complements
the486 behavior cases and six direct compiler/admission cases already passed; the repair changes only
the provenance comment. Full recorded reversals preserve both complete test baselines.

| Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0 | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
|core/:cabal test all|18:29:44.809827 to18:35:01.180014|316.372099|All3940 passed,304.76 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|18:29:44.822178 to18:35:00.613985|315.793716|All167 passed,1.52 reported seconds; All3940 passed,305.20 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|18:29:44.810946 to18:29:45.602308|0.791352|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|18:29:44.810088 to18:29:51.728863|6.918799|376 passed,5.90 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1062 audited files,936 Haskell paths and95 docs match the retained Linux tree; all frozen-after
checks pass. Final snapshot digests are all9365ac94b5b67f64858a317df84019f2c13fa95cbc5742c2106065aca65342b32f6,
core-owned91136740c0d4b9b22b9e61e275717d28107ec42482517029f40db92f41bd03ce143,
docs9502b1eb24cef1deb7e3a05cead7e44114d817a3a0ae91397173e8354b7abec2bc.
Root preservation proves925 unrelated Haskell files,all640 old fixtures,all unowned baseline texts
and Cabal/project metadata exact; two new fixtures equal the measured pre-edit subjects. The Activation
export pin alone adopts the sealed contract; other96 pins,compiler matcher/resolvers,eight Rooted
positive controls,Handoff193 labels/18 literal hashes/helper suffix and seven activation axes remain
exact. Production220/235 lines across three modules; specs689/694 and docs30/32,with full baseline
reversals. Phase1 covered inputs are unchanged and its digest check passes within DocValidatorSpec.
No Docker base/warm-store inputs change. Negative-fixture diagnostics are retained; actual final
suite/parent results pass. The phase's own declared closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T18:35:32.588049+00:00 to 2026-11-02T18:35:38.351202+00:00,
5.763170 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.55: Measured instances have checked producers and a total fold [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Seal the existing MeasuredInstance sum with its two real producers and total pure elimination.
Activation,Command and RoleLifecycle are the exact three-module production closure.

#### Deliverables

- Hide both constructors; add kubernetesInstance and hostServiceInstance with only existing
  nonempty UID/nonce checks and exact ActivationInstanceInvalid details. Word64 restart0 and
  long nonempty nonces remain valid.
- Add a pure total descriptive fold. Preserve instanceIdentityText,Show and framed instance-key bytes.
- Adopt the two actual Command construction branches and RoleLifecycle pattern elimination.
  Preserve actual measured UID/protected nonce origin and existing activation-error rendering; add no
  invented authority. A present empty UID/nonce observed by the existing reader is refused at the
  measuredServiceInstance producer,after key/store/executable-hash work and before
  runInstalledServiceProgram loads revision files or admits manifests. Pinned Windows lookupEnv maps
  raw blank values to absence,retaining its earlier exact missing-coordinate fallback. Own both
  before-file refusal paths explicitly; do not claim an unentered Windows producer branch.
- Replace invalid-constructor tables with real producer refusals. Add constructor-requesting
  negatives for both branches,actual positives and fold cases; no meaningless coercion proof for a sum.
- Adopt only owned exports/tests/docs; preserve valid vectors,policy/store binding and seven axes.

#### Validation

ActivationSpec checks both empty refusals,restart0/long-nonce admission and total elimination.
RoleLifecycleSpec retains its real collision/length/long-nonce reservation controls and adds independent
literal framed instance-key vectors; the prior suite did not contain fixed SHA goldens. Measure
constructor diagnostics.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure. CLISpec observes actual service
command raw-empty UID/nonce refusals with scoped environment restoration,exact diagnostics and no handler
callback. The existing reader is retained: pinned Windows ordinary lookupEnv observes a present blank
as Nothing and reaches the exact missing-coordinate fallback; POSIX observes Just empty and reaches
the exact checked-producer refusal. Tests create/restore actual blank variables through
System.Environment.Blank,assert both the blank-preserving observation and the fixed host reader
observation,and exercise the actual CLI before revision-file loading. These are two executed cases
on every host,with no skip or Unsupported result; only the POSIX case claims producer-refusal timing.

Dated2026-11-02 baseline at18:35:51.998892 UTC captures48 texts,936 Haskell files and642 fixtures.
Before source changes,the actual unchanged100-argument native GHC context compiles the explicit
constructor-requesting subjects ConstructKubernetesInstance.hs(3316c4385b73c89971a3ff7adb63ae4b358f9b85fe4e982101cb4c779f95fa76)
at18:36:24.578363 to18:36:24.755213 UTC in0.176848 seconds,and
ConstructHostServiceInstance.hs(268f72cba11252e819c5aa7dec9371ef0720fc101cf79103fcb9b6ea7f8cf9ee)
at18:36:24.755264 to18:36:24.927478 UTC in0.172225 seconds,both0/empty stderr.
The lawful old-constructor Show witness(edf690a91a844c73c21fac83799843143edb18b8aa058e856294ce59cad818da)
compiles18:36:24.927537 to18:36:26.691757 UTC in1.764242 seconds and executes
18:36:26.691777 to18:36:26.747502 UTC in0.055736 seconds,both0/empty stderr.
Four actual cases cover escaped UID/restart0,Word64maxBound,escaped host nonce and10000-character
host nonce:20 Show rows plus4 identity outputs are captured,not fabricated. All48 source/metadata
subjects remain frozen. After witness004590445c7a901849d229166c3c6f22a899fcd67705c78b85c034e3606e2c2a
uses real producers with identical inputs/main/observations.

Production freezes65 nonempty/69 physical changed lines across Activation,Command and RoleLifecycle.
The native Windows main build passes18:38:32.591995 to18:38:47.072798 UTC in14.480890 seconds,
0/empty stderr. Both identical constructor subjects now fail1/GHC-10237 because exported
MeasuredInstance has no child named KubernetesInstance or HostServiceInstance:18:38:51.443780
to18:38:51.559590 UTC,0.115810 seconds,and18:38:51.559648 to18:38:51.680911 UTC,
0.121272 seconds. The public producer/fold/identity positive(009858e9daf199545e66a77b184fecceccf92154ec2f61106ea6482060ca180c)
passes18:38:51.680940 to18:38:51.864441 UTC in0.183512 seconds,0/empty stderr.
The after Show witness compiles18:38:51.864502 to18:38:53.664017 UTC in1.799536 seconds
and executes18:38:53.664038 to18:38:53.719829 UTC in0.055801 seconds,both0/empty stderr:
all20 Show and4 identity outputs equal the actual before vectors. Production/compiler metadata stays
frozen. The constructor sum/Eq/Show,identity text,validation/verifier/seven-axis suffix and sealed
manifest region remain raw-exact; Role key field order/tags are unchanged through pure elimination.
All928 unrelated Haskell files and642 old fixtures are exact.

The proposed CLI fixture's ordinary setEnv-empty setup was caught before execution: it unsets the
variable. A native pinned-GHC base-only probe compiles18:45:41.632193 to18:45:43.162598 UTC in
1.530414 seconds and runs18:45:43.162614 to18:45:43.292645 UTC in0.130039 seconds,both0/
empty stderr. A genuine blank has ordinary lookup Nothing,Blank.getEnv Just empty and an enumerated
empty value; nonempty is observed by all readers and absent by none. This establishes the declared
platform-specific test expectations without changing the production reader or claiming an unentered
Windows producer branch.

The final source audit19:24:58.130555 to19:24:58.192794 UTC independently reverses every
declared file to its whole baseline:production65/69 lines,specs337/344,docs17/19. Root preservation
19:24:25.189241 to19:24:25.477494 UTC passes928 unrelated Haskell files,642 old fixtures,all938
paths,unowned baseline texts/Cabal metadata,LF and scoped diff check.
Native Windows test compilation passes19:23:51.026745 to19:25:23.045830 UTC in92.019662
seconds,0/empty stderr,actual threaded RTS. The29 direct instance/CLI/compiler/inventory/documentation
cases pass19:25:45.405025 to19:25:54.480106 UTC,8.97 reported/9.075120 wall seconds,
0/empty stderr,frozen source/binary/metadata. All20 Show/four identity observations and five real
protected-reservation key goldens pass. Both actual raw-empty CLI cases prove the exact Windows
fallback,before file loading,with no handler callback. The affected native catalogue selects293 cases.
Its first test process passes293 cases in55.51 reported/55.602495 wall seconds,but the wrapper
refuses the frozen snapshot because this phase's evidence prose was updated during the run.
Only that phase document changes; no source/test/binary/compiler metadata changes. The repeated
batch passes19:27:27.337525 to19:28:31.002231 UTC in63.53 reported/63.665088 wall seconds,
parent0,all frozen bytes exact. Expected old CLI negative-fixture diagnostics are retained.

| Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0 | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
|core/:cabal test all|19:27:01.887524 to19:34:23.327125|441.442366|All3948 passed,311.78 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|19:27:01.886676 to19:34:20.688726|438.804795|All167 passed,1.69 reported seconds; All3948 passed,311.68 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|19:27:01.887001 to19:27:03.084696|1.197688|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|19:27:01.887360 to19:27:09.018815|7.131484|376 passed,5.74 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1064 audited files,938 Haskell paths and95 docs match the retained Linux tree; every full-command
frozen-after check passes. Snapshot digests are all93810b54a0030ebb5c1c058324e6b80eb332a3f86bfad6af1baea72fb8f9c704c61,
core-owned913bef529898eb3c0ca7707c653229d591c27dcca3caf062d30b7d7eb46c85442c7,
docs954c05af1ca50ab69dcf52470f047d267765d57cfcb9cc5c689debbee72f60b61c.
Root preservation passes928 unrelated Haskell files,all642 prior fixtures,all unowned baseline texts
and Cabal/project metadata. Only the owned Activation export pin changes; other96 pins,compiler
matcher/resolvers,eight Rooted positives,seven activation axes and the entire sealed-manifest contract
remain exact. Two new constructor subjects equal their actual pre-edit bytes. The recorded complete
reversals pass every changed production/test/doc file. The production delta is65/69 lines across3
modules,no new named type; specs337/344 and docs17/19. Phase1 inputs remain unchanged and its
digest check passes in DocValidatorSpec. No base-image/warm-store inputs change. Provider-live is
explicitly not requested/Unsupported; no live-substrate claim is made. Actual final suites and parents
pass; expected negative-fixture stderr is retained. The phase's own declared closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T19:34:45.677524+00:00 to 2026-11-02T19:34:51.509758+00:00,
5.832252 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.56: SelectedActivationManifest is a distinct verifier input [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Introduce only the selected manifest role and its complete two-module production caller adoption.
This is one new named DATA type; role assignment does not mint verified activation authority.

#### Deliverables

- Add only abstract SelectedActivationManifest,total selectedActivationManifest assignment from a
  validated manifest and ordinary selectedActivationManifestValue elimination. This inert DATA role
  establishes no independent provenance or effect authority; it adds no new manifest validation.
- Retype only the canonical verifier's actual selected input and Service's sole production call.
  Unwrap before unchanged runtime checks; add no raw-shaped compatibility verifier.
- Keep valid wire/signatures,policy/store binding,ordered mismatch diagnostics and all seven
  verified-activation nominal identities exact.
- Adopt EscapeVerifiedRuntimeRoleActivationFrame.hs's actual parameter interface and reprobe
  all seven original escape reasons. Unrelated fixtures and eight Rooted positives remain exact.
- Add actual-position raw-role,constructor-requesting and representation-coercion negatives for
  SelectedActivationManifest,matching positives,and only this role's exact export/doc adoption.

#### Validation

ActivationSpec retains actual verifier behavior. Measure real public-context positives/negatives and
all seven old escape blocks before registration.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline19:35:08.268295 UTC captures49 texts,938 Haskell files and644 fixtures,
including the unchanged seven-axis escape subject(ca0c705957752f33248c32ef45d8ae5cb99232116be7f578e85f54fe6d70bf0e).
Before edits,the real100-argument native GHC context compiles RawManifestAsSelectedActivation.hs
(086398ef5e492189de972343625c72810e76ee3d1cd8a8b8ee7286585de82377),which passes a raw
manifest at the actual third verifier argument,19:35:36.457975 to19:35:36.668196 UTC,
0.210221 seconds,0/empty stderr. The existing escape subject produces exactly seven error blocks
19:35:36.668246 to19:35:36.877490 UTC in0.209255 seconds,exit1. All49 source/metadata
subjects stay frozen. Production adds the selected role and its total producer/eliminator,changes only the selected verifier
type/pattern and Service's actual role assignment. The19 nonempty/22 physical production-line delta
stays within two modules. The actual verifier guard/body/suffix is byte-exact; no compatibility verifier
is added. All18 ActivationSpec calls and11 RoleLifecycleSpec calls assign the selected role; the test
alias itself is retyped and remains an exact canonical-verifier alias. Removing only those assignments,
the one signature adoption and the new role-law case restores both entire prior test files.

Native Windows Main passes19:36:29.287927 to19:36:43.868732 UTC in14.580903 seconds,
0/empty stderr. The unchanged raw-role subject now fails1/GHC-83865 at the actual third argument
19:39:52.339212 to19:39:52.561125 UTC in0.221911 seconds.
ConstructSelectedActivationManifest.hs(2e1cc98571ce4929a9963533157da5dbe56d4252dc8b924b7d7aa5931a55e0e8)
fails1/GHC-01928,19:39:52.561180 to19:39:52.806877 UTC,0.245709 seconds;
CoerceSelectedActivationManifest.hs(e0c5d553eae1f975a353c6af6e24438305051dec5e99316ec483b850f9238ace)
fails1/GHC-18872,19:39:52.806932 to19:39:53.027684 UTC,0.220764 seconds.
The public assignment/elimination/actual-verifier positive(dc5726d161d10cf798d7fac9abae87314f0c1ddec6050cf89a0243b3f2ad711b)
passes19:39:53.027736 to19:39:53.242751 UTC in0.215027 seconds,0/empty stderr.
The adapted old escape subject changes only its one explicit selected-parameter annotation; all seven
actual calls and selector bodies remain exact. It fails19:39:53.242808 to19:39:53.480350 UTC in
0.237555 seconds with exactly seven errors and all seven prior named mismatch reasons identical.

Root source audit19:41:28.895630 to19:41:29.013982 UTC passes full-file reversals:production19/22,
tests126/127,docs10/12. Preservation19:42:40.138775 to19:42:40.424590 UTC passes931 unrelated
Haskell files,643 unrelated old fixtures,all941 paths,unowned baseline texts/Cabal metadata,LF and
scoped diff check; three new subjects equal their measured bytes. Native test compilation passes
19:41:29.381073 to19:42:50.948983 UTC in81.568419 seconds,0/empty stderr,rts_thr,
all captured source/metadata frozen. The24 direct selected-role/compiler/inventory/escape/documentation cases pass19:43:53.565203
to19:44:02.258419 UTC in8.58 reported/8.693249 wall seconds,parent0/empty stderr.
The complete affected native selection passes294 cases19:44:02.492516 to19:45:03.412486 UTC
in60.81 reported/60.920337 wall seconds,parent0,frozen source/binary/compiler metadata.
Expected pre-existing CLI negative-fixture diagnostics are retained; actual suite results pass.

| Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0 | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
|core/:cabal test all|19:44:43.493402 to19:52:17.278456|453.787897|All3953 passed,339.76 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|19:44:43.493094 to19:52:06.884549|443.394228|All167 passed,1.86 reported seconds; All3953 passed,340.11 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|19:44:43.499911 to19:44:44.465916|0.965985|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|19:44:43.515389 to19:44:51.278605|7.763243|376 passed,6.40 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1067 audited files,941 Haskell paths and95 docs match the retained Linux tree; every full-command
frozen-after check passes. Snapshot digests are all9411beb445990de5809ce99ab97f03d0600720157409d1d5f46354b350aedd16dd6,
core-owned9160690e656c99ed9489731cf5adb5862ea550d512d12e1f62d88d89919db917859,
docs95752ac96fff0d954e7031dce62b4e85b833cbab9b170b22c1cf8ae9b5ccef2cec.
Root preservation passes931 unrelated Haskell files,643 unrelated prior fixtures and all unowned
baseline texts/Cabal metadata. The sole related old escape fixture changes one explicit parameter
annotation; all seven original refusal reasons and bodies remain exact. Three new subjects equal their
measured bytes. Only the owned Activation pin changes; other96 pins,eight Rooted positives,compiler
matcher/resolvers,canonical wire/signatures/policy/store checks and all seven verified activation axes
remain exact. Full recorded reversals pass production19/22 lines in two modules,tests126/127,docs10/12;
one new named DATA type. Phase1 inputs and digest are unchanged; DocValidatorSpec proves currency.
No base-image/warm-store input changes. Provider-live is not requested/Unsupported; no live-substrate
claim is made. Final suites/parents pass,with expected negative diagnostics retained. The phase's own
declared closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T19:53:02.370144+00:00 to 2026-11-02T19:53:08.245867+00:00,
5.875742 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.57: ReceivedActivationManifest is a distinct verifier input [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Introduce only the received manifest role and its complete two-module production caller adoption.
This is one new named DATA type; role assignment does not mint verified activation authority.

#### Deliverables

- Add only abstract ReceivedActivationManifest,total receivedActivationManifest assignment from a
  validated manifest and ordinary receivedActivationManifestValue elimination. This inert DATA role
  establishes no independent provenance or effect authority; it adds no manifest validation.
- Retype only the canonical verifier's actual received input and Service's sole production call.
  Unwrap before unchanged runtime checks; add no raw-shaped compatibility verifier.
- Keep valid wire/signatures,policy/store binding,ordered mismatch diagnostics and all seven
  verified-activation nominal identities exact.
- Adopt EscapeVerifiedRuntimeRoleActivationFrame.hs's actual parameter interface and reprobe
  all seven original escape reasons. Also adopt the received parameter of the prior selected-position
  refusal subject and its public control,retaining the single intended selected-slot diagnostic.
  Unrelated fixtures and eight Rooted positives remain exact.
- Add actual-position raw-role,constructor-requesting and representation-coercion negatives for
  ReceivedActivationManifest,matching positives,and only this role's exact export/doc adoption.
- Add SwapActivationManifests.hs using both genuine opaque roles at the actual adjacent
  verifier slots,with a matching positive and both complete transposition diagnostic blocks.

#### Validation

ActivationSpec retains actual verifier behavior. Measure real public-context positives/negatives and
all seven old escape blocks before registration.
The two-role swap must fail at the actual verifier inputs.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline19:53:17.475387 UTC captures50 texts,941 Haskell files and647 fixtures,
including both related prior refusal subjects. Before edits,the actual100-argument native GHC context
compiles RawManifestAsReceivedActivation.hs(df5cbbb30c65aad66b02a423cb62709697be0875e8a003719a85b889981756ab),
which takes an opaque selected role and passes a raw manifest at the actual fourth verifier argument,
19:53:30.705202 to19:53:30.917036 UTC in0.211833 seconds,0/empty stderr.
The existing escape subject retains exactly seven error blocks19:53:30.917085 to19:53:31.132073 UTC,
0.214999 seconds,exit1. The prior selected-position subject retains one error19:53:31.132117
to19:53:31.363891 UTC,0.231784 seconds,exit1. All50 source/metadata subjects remain frozen.
Production adds only the received DATA role/total producer/ordinary eliminator,changes the canonical
fourth input type/pattern and Service's actual received assignment. The19 nonempty/22 physical
production-line delta stays within two modules. Both wrappers are unwrapped before the byte-exact
existing verifier guard/body/suffix. All18 ActivationSpec and11 RoleLifecycleSpec calls assign the
received role explicitly; the existing alias retains the canonical typed verifier. Removing only those
assignments,the one signature adoption and new role-law case restores both entire prior test files.

Native Windows Main passes19:54:27.999097 to19:54:49.530540 UTC in21.531577 seconds,
0/empty stderr. The unchanged raw-received subject now fails1/GHC-83865 at the actual fourth
argument19:56:09.187116 to19:56:09.405910 UTC in0.218793 seconds.
ConstructReceivedActivationManifest.hs(8868867bc4e6662ea2de5fb6bd8d59d03656795f36aa2e7479e06db53055ae21)
fails1/GHC-01928,19:56:09.405962 to19:56:09.610499 UTC,0.204549 seconds;
CoerceReceivedActivationManifest.hs(3fe68553dbc1284d7c725f1292b56d5d76416bcaf7cc3df2bb72784288047a13)
fails1/GHC-18872,19:56:09.610549 to19:56:09.817030 UTC,0.206501 seconds.
SwapActivationManifests.hs(f22994ce553a6f58ec4714a124db20a8a4db360c2bf350caf3591026ea22ee5d)
passes genuine opaque selected/received parameters in reversed actual positions and produces exactly
two GHC-83865 blocks,third and fourth arguments,19:56:09.817089 to19:56:10.032688 UTC,
0.215611 seconds,exit1. The matching public assignment/elimination/ordered-role control
(09dd0b7b3503106ca1530aec1ea3fca9cd9c652d0acb8e1093637d5c2a2a7bb7) passes
19:56:10.032744 to19:56:10.233526 UTC in0.200792 seconds,0/empty stderr.

The adapted escape subject retains exactly seven errors and identical old named reasons
19:56:10.233576 to19:56:10.460864 UTC,0.227300 seconds,exit1.
The prior selected-position subject adopts only the received parameter/import; it retains exactly its
one old selected-slot error19:56:10.460924 to19:56:10.678990 UTC,0.218077 seconds,exit1.
Its public positive likewise uses genuine received assignment; no refusal matcher is weakened.

Root source audit19:57:32.092516 to19:57:32.225500 UTC passes complete reversals:production19/22,
tests152/153,docs11/13. Preservation19:58:20.548915 to19:58:20.818687 UTC passes933 unrelated
Haskell files,645 unrelated old fixtures,all945 paths,unowned baseline texts/Cabal metadata,LF and
scoped diff check. Related old fixtures change only declared received interfaces; all four new subjects
equal measured bytes. Native test compilation passes19:57:32.581841 to19:58:48.402263 UTC
in75.820898 seconds,0/empty stderr,rts_thr,frozen captured source and metadata.
The27 direct role/compiler/inventory/old-boundary/documentation cases pass19:59:43.054679
to19:59:51.954149 UTC in8.79 reported/8.899505 wall seconds,parent0/empty stderr.
Both distinct swap blocks and all prior intended refusals pass the unchanged diagnostic matcher.
The complete affected native selection passes295 cases19:59:52.167484 to20:00:48.499814 UTC
in56.23 reported/56.332670 wall seconds,parent0,frozen source/binary/compiler metadata.
Expected pre-existing CLI negative-fixture diagnostics are retained; actual suite results pass.

| Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0 | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
|core/:cabal test all|20:00:34.196584 to20:07:06.280765|392.086636|All3959 passed,293.89 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|20:00:34.196405 to20:06:55.712634|381.518613|All167 passed,1.45 reported seconds; All3959 passed,291.64 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|20:00:34.196509 to20:00:35.051553|0.855028|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|20:00:34.209106 to20:00:41.369201|7.160121|376 passed,5.99 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1071 audited files,945 Haskell paths and95 docs match the retained Linux tree; every full-command
frozen-after check passes. Snapshot digests are all945fc15497cbf10b668616e802aee4a1d28d003b4eae7f5da054cb5600a282e700e,
core-owned92074effaa6e0672a0e53ecbe10e3977ab91d6dfe437eda1fc55c4bfeccf215b7c5,
docs953b7f02912a0588c728bd3c24b2f1e794627d109f42ebd62bde57ce182143dc50.
Root preservation passes933 unrelated Haskell files,645 unrelated prior fixtures and all unowned
baseline texts/Cabal metadata. The two related old negatives change only received interfaces; all
seven escape reasons and the selected-slot subject's single intended reason remain exact. Four new
subjects equal their actual measured bytes. Only the owned Activation pin changes; other96 pins,
eight Rooted positives,compiler matcher/resolvers,canonical wire/signatures/policy/store checks and
all seven verified activation axes remain exact. Full reversals pass production19/22 lines in two
modules,tests152/153,docs11/13;one new named DATA type. Phase1 inputs/digest are unchanged and
DocValidatorSpec proves currency. No base-image/warm-store input changes. Provider-live is not
requested/Unsupported;no live-substrate claim is made. Final suites/parents pass,with expected negative
diagnostics retained. The phase's own declared closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T20:08:21.727490+00:00 to 2026-11-02T20:08:27.317266+00:00,
5.589794 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.58: BuildProjectName is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuildProjectName its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuildProjectName,total buildProjectNameFromText DATA assignment and ordinary
  buildProjectNameText elimination. Keep the existing buildProjectName record getter at the typed
  field; delegate the role's Show exactly to underlying Text so existing binding Show stays compatible.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer and verifier project input.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add actual-position raw/constructor/coerce negatives and matching positives for BuildProjectName.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline20:08:46.376479 UTC captures55 texts,945 Haskell files and651 fixtures.
Before any production edit,the real100-argument native GHC context compiles
RawTextAsBuildProjectName.hs(9b42432ecfc986066b07937ca7bbfad9d6e381f9e16beb6fd3cae888549952d0),
which supplies raw Text at the actual project verifier argument,20:10:10.698142 to20:10:10.868494 UTC,
0.170350 seconds,0/empty stderr. The existing build escape subject retains seven errors
20:10:10.868546 to20:10:11.046703 UTC,0.178167 seconds,exit1.
The actual binding/Show/signature witness(77922f49833b79b1cfe72a7505ef737d20309681fb1631f612d346d8abb6ffee)
compiles20:10:11.046769 to20:10:12.736663 UTC,1.689914 seconds and executes20:10:12.736681
to20:10:12.790431 UTC,0.053760 seconds,both0/empty stderr.

An independent encoder frames the explicit UTF-8 fields hostbootstrap-demo,spec-1,config-1,build-7,
source-digest,coordinator-digest,builder-digest,image-build-container-0 with unsigned64 big-endian
lengths. Its171-byte literal exactly equals the observed production renderer; SHA256 is
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
A separately assembled escaped-project vector also matches. Fifteen actual observations capture
both bindings'wire bytes,Show at0/10/11 and Maybe/list,descriptive project text,and the actual signature
from a synthetic provisioned seed. Expected bytes and observed outputs are separate; all55 source/
metadata subjects remain frozen. The production role adds39 nonempty/43 physical lines across Build,Command and demo Commands.
The binding's project field/decoder/renderer and canonical project input are typed; only the actual
Command verifier argument and two demo binding fields adopt the role. Show delegates to underlying
Text. Every other binding coordinate and verifier code from the spec comparison onward is byte-exact.

Native Windows core Main passes20:13:23.174698 to20:13:44.918474 UTC in21.743913 seconds,
0/empty stderr. Native demo Main passes20:17:24.351813 to20:17:51.311635 UTC in26.959984
seconds,0/empty stderr. The unchanged raw-Text subject now fails1/GHC-83865 at the actual second
verifier argument20:16:32.973647 to20:16:33.149992 UTC in0.176341 seconds.
ConstructBuildProjectName.hs(cf108b1dde4f0e3c815f23059b8fab4e4dcd86546cb657ea45678d1ea383c54a)
fails1/GHC-01928,20:16:33.150040 to20:16:33.310505 UTC,0.160475 seconds;
CoerceBuildProjectName.hs(657786f6663921f9ef449f579f4deae06883ca1c8a2e5b14f0e3a3288bd8df31)
fails1/GHC-18872,20:16:33.310551 to20:16:33.479825 UTC,0.169285 seconds.
The public factory/eliminator/typed-field/actual-verifier positive
(2814d0c431a8532bcc92423f03243bbc0903f32931f556cace8b59819e5ef375) passes20:16:33.479871
to20:16:33.652059 UTC in0.172199 seconds,0/empty stderr.
The build escape alias changes only its project input type and retains seven identical old named
reasons20:16:33.652109 to20:16:33.832910 UTC,0.180813 seconds,exit1.
The completely unchanged coordinator escape subject retains its one refusal20:16:33.832962
to20:16:34.000558 UTC,0.167607 seconds,exit1.

The after binding witness(22b373c692f1a8f7e4b7e1f1cd50a24b4b577266be913edf35625df159cc16e0)
compiles20:16:34.000715 to20:16:35.699711 UTC in1.699017 seconds and executes
20:16:35.699731 to20:16:35.757147 UTC in0.057425 seconds,both0/empty stderr:
all15 actual wire/Show/getter/signature observations equal the before capture. The new test cases
pin the independently assembled bytes and measured compatibility literals,plus empty/space/escaped
descriptive role admission. Existing genuine signed empty-id/frame refusals remain present.

Root source audit20:21:00.974875 to20:21:01.141531 UTC passes complete reversals:production39/43,
tests173/181,docs10/12. Preservation20:22:59.471561 to20:22:59.897686 UTC passes938 unrelated
Haskell files,650 unrelated old fixtures,all948 paths,other baseline texts/Cabal metadata,LF and
scoped diff check; the related old fixture changes one project annotation and three new subjects
equal measured bytes. Core native test compilation passes20:21:03.849353 to20:21:53.519520 UTC
in49.670468 seconds,0/empty stderr,rts_thr,frozen source/metadata. The26 direct project-role/literal/compiler/old-boundary/inventory/documentation cases pass
20:25:36.012051 to20:25:46.786984 UTC in10.66 reported/10.774979 wall seconds,parent0/
empty stderr. The complete affected native selection passes246 cases20:25:47.011382 to20:26:51.142302
UTC in64.04 reported/64.131292 wall seconds,parent0,frozen source/binary/compiler metadata.
Native demo test compilation passes20:24:49.590116 to20:25:08.381217 UTC in18.791215
seconds,0/empty stderr,rts_thr. The entire native demo suite passes167 cases20:27:31.080293
to20:27:36.229465 UTC,5.12 reported/5.149179 wall seconds,parent0,frozen source/binary and
actual compiler metadata. Its expected existing teardown-refusal fixtures intentionally emit diagnostics;
actual suite results pass.

Demo validation uses the actual existing metadata path C:\Users\matth\hostbootstrap\demo\dist-newstyle\cache\plan.json; optional reported
build-info existence is False. No absent artifact is claimed.

| Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0 | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
|core/:cabal test all|20:27:18.743777 to20:33:32.417332|373.675819|All3965 passed,318.12 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|20:27:18.743352 to20:33:25.611894|366.870752|All167 passed,1.63 reported seconds; All3965 passed,319.81 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|20:27:18.743692 to20:27:19.593849|0.850143|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|20:27:18.743554 to20:27:25.988362|7.244834|376 passed,6.12 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1074 audited files,948 Haskell paths and95 docs match the retained Linux tree; every full-command
frozen-after check passes. Snapshot digests are all9481d99e0dd0297c69db3f1fb1acc5ff8cb59dc0c18c1cbe826ee8f030ddc957172,
core-owned923919af64724f91451c16fb5dfaae8b0b23aa0600c33038c3b8d3e90d440c02520,
docs95f53ce02038f1fca4e2c1c24a9d38234f590db3e6dca58e9e64e3aca604556c54.
Root preservation passes938 unrelated Haskell files,650 unrelated prior fixtures and all unowned
baseline texts/Cabal metadata. The build escape alias changes only its project type,retaining all
seven named reasons; coordinator escape bytes/refusal remain exact. Three new subjects equal their
actual measured bytes. Only the owned Build pin changes; other96 pins,eight Rooted positives and
generic compiler readers/matchers remain exact. Every other binding coordinate,source golden,
signed empty-id/frame refusal and authority nominal axis remains intact. Full reversals pass
production39/43 lines across three modules,tests173/181,docs10/12;one new named DATA type.
The independent171-byte binding literal and all15 actual compatibility observations remain exact.
Phase1 inputs/digest are unchanged; DocValidatorSpec proves currency. No base-image/warm-store
input changes. Provider-live is not requested/Unsupported;no live-substrate claim is made.
Final suites/parents pass,with expected negative diagnostics retained. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T20:34:00.810248+00:00 to 2026-11-02T20:34:06.390383+00:00,
5.580151 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.59: BuildSpecDigest is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuildSpecDigest its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuildSpecDigest,total buildSpecDigestFromText DATA assignment and ordinary
  buildSpecDigestText elimination. Retain the existing typed buildSpecDigest field getter and delegate
  the role's Show to underlying Text,keeping existing binding display compatible.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer and verifier spec input.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Retype the prior raw-project
  refusal subject's spec input and its public positive,retaining its single intended project-slot error.
  Preserve all seven EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also
  retains the original EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter
  or matcher weakening.
- Add actual-position raw/constructor/coerce negatives and matching positives for BuildSpecDigest.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline20:34:31.301413 UTC captures56 texts,948 Haskell files and654 fixtures.
The actual100-argument native GHC context compiles RawTextAsBuildSpecDigest.hs
(26fe74a0bd7492cc72280d11254c4b3e31bf6dfff06bd53027818403e7134163),which takes the opaque
project role and raw spec Text at the actual third verifier input,20:35:00.584197 to20:35:00.760303
UTC,0.176105 seconds,0/empty stderr. The old build escape retains seven errors20:35:00.760358
to20:35:00.956905 UTC,0.196558 seconds; the prior raw-project subject retains one error
20:35:00.956970 to20:35:01.147518 UTC,0.190558 seconds,both exit1.
The binding compatibility witness22b373c692f1a8f7e4b7e1f1cd50a24b4b577266be913edf35625df159cc16e0
compiles20:35:01.147579 to20:35:02.830306 UTC in1.682747 seconds and executes
20:35:02.830326 to20:35:02.884101 UTC in0.053785 seconds,both0/empty stderr. It preserves all15
actual observations and again matches the independent171-byte binding vector
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
All56 source/metadata subjects remain frozen. Production adds39 nonempty/43 physical lines across Build,Command and demo Commands. The spec
field/decoder/renderer and canonical third input are typed; only the actual finalized-codec observation
and two demo binding fields assign the role. All other binding coordinates and verifier code from the
config comparison onward remain byte-exact. The role's Show delegates to underlying Text.

Native Windows core Main passes20:36:09.804172 to20:36:32.441151 UTC in22.637119 seconds,
0/empty stderr. Native demo Main passes20:37:41.874934 to20:38:02.316169 UTC in20.441358
seconds,0/empty stderr. The unchanged raw-spec subject now fails1/GHC-83865 at the actual third
argument20:37:52.046011 to20:37:52.226743 UTC in0.180731 seconds.
ConstructBuildSpecDigest.hs(1d767f3cb80552a98e05c79c36a057b5b19056c85b051f3bad6042b9cc769963)
fails1/GHC-01928,20:37:52.226795 to20:37:52.435894 UTC,0.209109 seconds;
CoerceBuildSpecDigest.hs(26744e78821f088e2710b98958b2462d1dd7b848492589d7826154aa3e21d071)
fails1/GHC-18872,20:37:52.435942 to20:37:52.626878 UTC,0.190946 seconds.
The matching public assignment/elimination/typed-field/verifier control
(0577729cf46e759d087caff960ebd85c3ad4615014f1a9ba606239f2d6a47461) passes20:37:52.626924
to20:37:52.812712 UTC,0.185800 seconds,0/empty stderr.

The prior project-position subject changes only its spec interface and retains its one old project
refusal20:37:52.812766 to20:37:53.014275 UTC,0.201519 seconds,exit1; its public positive
uses genuine spec assignment. The build escape alias retains all seven prior reasons20:37:53.014320
to20:37:53.209862 UTC,0.195553 seconds,exit1. Coordinator escape bytes and its one refusal remain
unchanged20:37:53.209915 to20:37:53.390166 UTC,0.180264 seconds,exit1.
The after compatibility witness8526db4632ee0de8f80a34a3a67152c0ceeed18ecfc7fb160202383f4151cd52
compiles20:37:53.390341 to20:37:55.446021 UTC,2.055702 seconds,and executes20:37:55.446040
to20:37:55.506393 UTC,0.060367 seconds,both0/empty stderr. All15 wire/Show/getter/signature
observations remain identical; no expected literal or refusal matcher is weakened.

Root source audit20:38:55.328576 to20:38:55.456035 UTC passes full reversals:production39/43,
tests95/97,docs9/11. Preservation20:39:37.772480 to20:39:38.060625 UTC passes940 unrelated
Haskell files,652 unrelated old fixtures,all951 paths,other baseline texts/Cabal metadata,LF and
scoped diff check. Two related old interfaces alone are adopted; three new subjects equal measured
bytes. Core native test compilation passes20:38:55.797270 to20:39:35.611556 UTC in39.814527
seconds,0/empty stderr,rts_thr,all captured inputs frozen. The29 direct spec/project/literal/compiler/old-boundary/inventory/documentation cases pass
20:40:22.670204 to20:40:33.647370 UTC in10.85 reported/10.977213 wall seconds,parent0/
empty stderr. The complete affected native selection passes247 cases20:40:33.913341 to20:41:59.078548
UTC in85.06 reported/85.165710 wall seconds,parent0,frozen source/binary/compiler metadata.
Native demo test compilation passes20:40:12.280408 to20:40:29.465821 UTC in17.185519 seconds,
0/empty stderr,rts_thr. All167 native demo cases pass20:41:38.273320 to20:41:43.474574 UTC,
5.16 reported/5.201258 wall seconds,parent0,frozen source/binary/actual metadata. Expected old CLI
and consumer teardown-refusal diagnostics are retained; actual test results pass.

| Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0 | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
|core/:cabal test all|20:41:27.972301 to20:48:01.715196|393.745278|All3970 passed,320.72 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|20:41:27.971483 to20:47:52.484973|384.515819|All167 passed,2.17 reported seconds; All3970 passed,322.98 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|20:41:27.972146 to20:41:29.083974|1.111810|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|20:41:27.972473 to20:41:36.528578|8.556135|376 passed,7.15 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1077 audited files,951 Haskell paths and95 docs match the retained Linux tree; every full-command
frozen-after check passes. Snapshot digests are all951a2e3b363d16c08bdae730bbfbc05bd317df130bac3462da270365da8da0397ad,
core-owned92622176f76ea43e82e69e2b3e0ed64ab242ce0e9e0ce1b74e5cf566a2f7b9b1a9a,
docs95b179dd2e62cfa37d4e2cf8114c22c1792dfaa88d8c68076514a311a7740808ba.
Root preservation passes940 unrelated Haskell files,652 unrelated old fixtures and unowned baseline
texts/Cabal metadata. The related build alias and project refusal subject change only spec interfaces;
all seven build reasons and the single intended project reason remain exact. Three new subjects equal
measured bytes. Only the owned Build pin changes; other96 pins,eight Rooted positives and generic
compiler readers/matchers remain exact. Existing independent binding/source vectors,all15 observed
wire/Show/getter/signature values,signed empty-id/frame refusals and authority nominal axes remain.
Full reversals pass production39/43 lines across three modules,tests95/97,docs9/11;one new DATA type.
Phase1 inputs/digest are unchanged and DocValidatorSpec proves currency. No base-image/warm-store
input changes. Provider-live is not requested/Unsupported;no live-substrate claim is made.
Final suites/parents pass with expected negative diagnostics retained. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T20:48:24.267138+00:00 to 2026-11-02T20:48:30.819728+00:00,
6.552613 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.60: BuildConfigDigest is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuildConfigDigest its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuildConfigDigest,total buildConfigDigestFromText DATA assignment and ordinary
  buildConfigDigestText elimination. Retain the typed buildConfigDigest field getter and delegate
  the role's Show to underlying Text,keeping existing binding display compatible.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer and verifier config input.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Retype the config inputs
  of prior raw-project/raw-spec subjects and their public controls,retaining each single intended
  refusal. Preserve all seven EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption
  also retains the original EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier
  adapter or matcher weakening.
- Add actual-position raw/constructor/coerce negatives and matching positives for BuildConfigDigest.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Add SwapBuildDigests.hs using both real spec/config types at actual slots with a matching positive
and complete independently named transposition blocks.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline20:48:40.620155 UTC captures57 texts,951 Haskell files and657 fixtures.
The actual100-argument native GHC context compiles RawTextAsBuildConfigDigest.hs
(0713ccc531b666fb536f6e3d3a7670ec74222f819d715a4211a79f3e41805969),which takes genuine
opaque project/spec roles and passes raw config Text at the actual fourth verifier input,
20:48:57.963790 to20:48:58.141534 UTC,0.177743 seconds,0/empty stderr.
The old build escape retains seven errors20:48:58.141587 to20:48:58.325140 UTC,0.183564 seconds.
The prior raw-project and raw-spec subjects each retain one intended error,20:48:58.325202
to20:48:58.497463 UTC,0.172271 seconds,and20:48:58.497518 to20:48:58.683914 UTC,
0.186408 seconds,all exit1. The binding witness8526db4632ee0de8f80a34a3a67152c0ceeed18ecfc7fb160202383f4151cd52
compiles20:48:58.683979 to20:49:00.494259 UTC,1.810302 seconds and executes
20:49:00.494282 to20:49:00.547896 UTC,0.053624 seconds,both0/empty stderr. All15 observed
compatibility values and the independent171-byte binding literal remain exact.
All57 source/metadata subjects remain frozen. Production adds39 nonempty/43 physical lines across Build,Command and demo Commands. The config
field/decoder/renderer and fourth verifier input are typed; assignment stays at the actual validated
config observation and two demo fields. Every other binding coordinate and verifier code from the
coordinator comparison onward remains byte-exact. Show delegates to underlying Text.

Native Windows core Main passes20:49:44.510825 to20:49:59.704035 UTC in15.193300 seconds,
0/empty stderr. Native demo Main passes20:51:05.832524 to20:51:26.127272 UTC in20.294870
seconds,0/empty stderr. The unchanged raw-config subject now fails1/GHC-83865 at the actual fourth
argument20:51:16.009370 to20:51:16.201562 UTC,0.192192 seconds.
ConstructBuildConfigDigest.hs(61ea8114ed48dc57953ab5517572cb742419e5280dfa917f61a476c7f3536c42)
fails1/GHC-01928,20:51:16.201617 to20:51:16.388061 UTC,0.186455 seconds;
CoerceBuildConfigDigest.hs(49d4e78a30da1336947f3825273942931adec25510fd77e5af70f424954dfae5)
fails1/GHC-18872,20:51:16.388111 to20:51:16.579734 UTC,0.191633 seconds.
SwapBuildDigests.hs(b281bf01fa82b72050fd547b578b3206237a6caa40c576842a7ffa64dec77483)
takes genuine opaque spec/config roles and swaps only their actual third/fourth arguments. It produces
exactly two complete GHC-83865 blocks20:51:16.579786 to20:51:16.761939 UTC,0.182168 seconds,
exit1. The matched public assignment/elimination/typed-field/ordered-role control
(2ffe296da31cc7120407a99c9977a92e58e9832ccf3b5e6f69fdbaee34ab3e19) passes20:51:16.762003
to20:51:16.959733 UTC,0.197740 seconds,0/empty stderr.

The prior raw-project and raw-spec subjects adopt config interfaces only; each retains exactly its
single old intended refusal20:51:16.959781 to20:51:17.144344 UTC,0.184574 seconds and
20:51:17.144397 to20:51:17.336922 UTC,0.192537 seconds,exit1. Both public controls use genuine
config assignment. The build escape retains all seven old reasons20:51:17.336972 to20:51:17.538010
UTC,0.201049 seconds,exit1; coordinator escape bytes/one refusal remain exact20:51:17.538061
to20:51:17.741126 UTC,0.203077 seconds,exit1.
After witness7e8f51321ed1adbb52cd420b93f3a8f0928525583ed4cab524901463c84ca4af compiles
20:51:17.741309 to20:51:19.636806 UTC,1.895521 seconds,and executes20:51:19.636829
to20:51:19.697150 UTC,0.060335 seconds,both0/empty stderr. All15 observed compatibility
values remain identical,including independent binding bytes,Show,getter and actual signature.

Root source audit20:52:10.342353 to20:52:10.480911 UTC passes full reversals:production39/43,
tests121/123,docs10/12. Preservation20:52:51.616675 to20:52:51.907064 UTC passes942 unrelated
Haskell files,654 unrelated fixtures,all955 paths,other baseline texts/Cabal metadata,LF and scoped
diff check. Three old interfaces alone are adopted; four new subjects equal measured bytes.
Core native test compilation passes20:52:10.833019 to20:52:52.142258 UTC in41.309488 seconds,
0/empty stderr,rts_thr,frozen source/metadata. The33 direct config/spec/project/literal/compiler/swap/old-boundary/inventory/documentation cases
pass20:53:36.485060 to20:53:48.623387 UTC,12.00 reported/12.138381 wall seconds,parent0/
empty stderr. The genuine two-role swap satisfies two separate complete diagnostic blocks without
weakening the matcher. The affected native selection passes248 cases20:53:48.853622 to20:55:12.510645
UTC,83.55 reported/83.657516 wall seconds,parent0,frozen source/binary/compiler metadata.
Native demo test compilation passes20:53:26.042305 to20:53:43.442590 UTC in17.400388 seconds,
0/empty stderr,rts_thr. All167 native demo cases pass20:54:45.144063 to20:54:50.328827 UTC,
5.14 reported/5.184774 wall seconds,parent0,frozen source/binary/actual metadata. Expected old CLI
and teardown-refusal fixture diagnostics are retained; actual test results pass.

| Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0 | UTC start to end,2026-11-02 | Wall seconds | Actual result |
|---|---|---:|---|
|core/:cabal test all|20:54:34.829512 to21:01:12.385631|397.558525|All3976 passed,328.03 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|20:54:34.829618 to21:01:01.376457|386.549181|All167 passed,2.25 reported seconds; All3976 passed,329.22 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|20:54:34.851256 to20:54:35.841135|0.989863|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|20:54:34.850725 to20:54:42.775954|7.925256|376 passed,6.61 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1081 audited files,955 Haskell paths and95 docs match the retained Linux tree; every full-command
frozen-after check passes. Snapshot digests are all9558221d5e669ab63c9fe4e1004771c4fef4506976625e4767abf3a2306b8955573,
core-owned93078c18a05b2915e2fe1dacb4ef09dd8199547d2d5237abe7711e10ba3c4265d16,
docs9569cf64c0ee26f49423c7d25997a1f13729a9bd78b38fe42e39d15f3557fc9723.
Root preservation passes942 unrelated Haskell files,654 unrelated old fixtures and all unowned baseline
texts/Cabal metadata. Three related interfaces alone are adopted; seven old build reasons and both old
single-slot reasons remain exact. Four new subjects equal their actual measured bytes. Only the owned
Build pin changes; other96 pins,eight Rooted positives,generic compiler readers/matchers,all other
binding coordinates and verifier code from the coordinator comparison onward remain exact.
Independent binding/source vectors,all15 compatibility observations,actual signatures,genuine signed
empty-id/frame refusals and authority nominal axes remain intact. Full reversals pass production39/43
lines across three modules,tests121/123,docs10/12;one new DATA type. Phase1 inputs/digest are unchanged;
DocValidatorSpec proves currency. No base-image/warm-store input changes. Provider-live is not
requested/Unsupported;no live-substrate claim is made. Final suites/parents pass,with expected negative
diagnostics retained. The phase's own declared closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T21:01:30.526796+00:00 to 2026-11-02T21:01:36.371408+00:00,
5.844629 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.61: BuildIdentifier is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuildIdentifier its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuildIdentifier,total buildIdentifierFromText DATA assignment and ordinary
  buildIdentifierText elimination. Keep the typed binding field and private authority description;
  preserve public authority getter Text and all prior display through total elimination.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer and authority description.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add raw/constructor/coerce negatives and matching positives for BuildIdentifier. Its actual raw
  position is the binding's identifier field,not an invented verifier argument; measure that field
  update. Preserve the descriptive authority getter's Text output through total elimination.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline21:01:48.020449 UTC captures57 texts,955 Haskell files and661 fixtures.
Before edits,the actual100-argument native GHC context compiles RawTextAsBuildIdentifier.hs
(f081b4eca0eec936938168b6830806a2650540a71fa8aea189b57de98ee16a41),which performs a real
Text update of the binding's identifier field,21:02:56.241613 to21:02:56.435980 UTC,
0.194365 seconds,0/empty stderr. The unchanged build escape retains seven errors21:02:56.436041
to21:02:56.640681 UTC,0.204651 seconds; prior raw project/spec subjects retain single intended
errors in0.192022/0.190980 seconds. The binding witness7e8f51321ed1adbb52cd420b93f3a8f0928525583ed4cab524901463c84ca4af
compiles21:02:57.023842 to21:02:58.949681 UTC,1.925860 seconds,and executes21:02:58.949701
to21:02:59.013310 UTC,0.063621 seconds,both0/empty stderr. All15 compatibility observations
and independent171-byte vector remain exact.

A separate genuine sign/measure/verify authority witness997f346cab0532a6ff2d53d809711acbc21f2e7582759a20bfddc0a96eb6c976
compiles21:03:21.753789 to21:03:23.704495 UTC in1.950716 seconds and executes
21:03:23.704512 to21:03:23.772685 UTC in0.068183 seconds,both0/empty stderr. Actual outputs
are ImageBuildFrame image-build-container-0,BuildInvocationAuthority build-7,identifier build-7,
source digest0442fec496cecddecd34f8ac04e9bbd6e2c1f202c605b9fb06c962138ea26472.
All57 source/metadata subjects remain frozen. Role/adoptions,after controls and all gates remain due.

Dated2026-11-02 implementation freeze:33 changed nonempty/37 physical production lines across
Build and demo Commands;one new descriptive type. Build SHA162071b30173e3297daf2acfdc83863df0bdaabc1d19f0fa1e9201bf2493c5e5;
demo Commands1d5818e69c6ee463fb7068cc14b95a4ee700ae2ebcfe323176ec46479bee05ea.
Total DATA assignment adds no validation;the old canonical empty-ID predicate alone gains total text
elimination. Its exact refusal,the coordinator-before-ID-before-frame order and all later verification
code remain unchanged. The public authority identifier getter remains Text. Generic measurements and
Command are unchanged. Full baseline reversals pass production33/37,tests92/94,docs11/13 lines.
Preservation holds950 unrelated Haskell files,all661 prior fixtures,all958 current paths,other96 export
pins,all unowned baseline texts and metadata. Only the Build export list gains the declared role API.
Both declared docs describe DATA distinction and the retained canonical check;no base/warm input changes.

Native core Main passes21:04:17.548216 to21:04:34.075874 UTC,16.527758 seconds,0/empty stderr.
Actual native demo Main passes21:07:55.699626 to21:08:10.963743 UTC,15.264209 seconds,0/empty
stderr. Production/metadata remain frozen. The actual100-argument after probes run21:08:32.718095
to21:08:37.840090 UTC:raw binding update now fails GHC-83865 at its identifier expression in0.183035
seconds;requested constructor fails GHC-01928 in0.178763;coerce fails GHC-18872 in0.180507.
Each has its complete intended diagnostic block. Matching typed factory/getter/field/update and public
Text authority-description control compiles in0.180362 seconds,0/empty stderr. The unchanged build
escape retains all seven original nominal reasons in0.189796 seconds;the unchanged coordinator
escape retains its one rank-2 refusal in0.206138 seconds. No raw verifier identifier slot is invented.
Binding witness96c535d04c34b9c7acf15d3956739d3fb83674f493208eb04bf49a8ab6be9258 compiles
in1.856212 seconds and executes in0.059022 seconds,both0/empty stderr:all15 actual wire/display/
signature observations equal the captured before values and independent171-byte literal vector.
Genuine authority witness49be76a8838d0fb94eb71fd5e2cdb90cb56c33889f048807bd6545740318d369
compiles in2.019212 seconds and executes in0.068526,both0/empty stderr:all four actual frame/
authority/getter/source observations equal the before control. All production/metadata stay frozen.

BuildAuthoritySpec adopts only the actual identifier assignments,adds the arbitrary/empty DATA law,
checks measured frame/authority display and retains the independent wire/signature literals. Its
otherwise valid genuinely signed empty-ID channel passes the real reader,then yields exactly
BuildChannelMalformed "the build id is empty",callback0;the existing signed empty-frame case remains.
CompileFailSpec registers the three measured negatives and exact matching public positive. Existing
generic compiler readers/matchers,Rooted controls and every prior fixture remain exact. Native core
test compilation passes21:09:27.012006 to21:10:10.395677 UTC,43.383935 seconds,0/empty
stderr,rts_thr,frozen sources/metadata. The final focused/consumer and static results follow.

Native demo test compilation passes21:10:37.976376 to21:10:59.245229 UTC in21.268981 seconds,
0/empty stderr,rts_thr,frozen source/metadata. Native completed selections:

|Actual selection|UTC start to end,2026-11-02|Wall seconds|Result|
|---|---|---:|---|
|Direct identifier/prior coordinate/literal/compiler/swap/escape/inventory/Doc|2026-11-02T21:10:38.268132+00:00 to2026-11-02T21:10:52.064826+00:00|13.796757|38 passed,13.62 reported seconds,parent0;frozen exact|
|Affected BuildAuthoritySpec/CLI/indexed project-plan/Doc|2026-11-02T21:10:52.308664+00:00 to2026-11-02T21:12:07.210301+00:00|74.902075|249 passed,74.79 reported seconds,parent0;frozen exact|
|Actual demo entire test component|2026-11-02T21:11:28.182601+00:00 to2026-11-02T21:11:33.342227+00:00|5.159636|167 passed,5.12 reported seconds,parent0;frozen exact|

Expected existing CLI and demo teardown-refusal diagnostics are retained;the selected tests and parents
pass. Actual demo plan.json and binary are frozen;its optional reported build-info file is absent.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T21:11:07.230358+00:00 to2026-11-02T21:17:48.076721+00:00|400.848837|All3981 passed,349.56 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T21:11:07.230237+00:00 to2026-11-02T21:17:46.076488+00:00|398.848710|All167 passed,1.83 reported seconds; All3981 passed,350.79 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T21:11:07.247254+00:00 to2026-11-02T21:11:08.149508+00:00|0.902239|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T21:11:07.269879+00:00 to2026-11-02T21:11:14.826128+00:00|7.556274|376 passed,6.30 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1084 audited files,958 Haskell paths and95 docs match the retained Linux tree;every full-command
frozen-after check passes. Dated snapshot aggregates:
- all958:010f363155c34550aeef38d8943690f1f0158b7d6d528ae251ff198355182a96
- owned933:540f3f75948a98a41881bef78e017ed4cb9877435b51bc8b84567ebf892c368c
- docs95:e3fc385bac5c955674e2220e39579167a8f90c3fc927e628cd15a8b7785e8dd3

Root preservation proves950 unrelated Haskell files,all661 old fixtures,other96 pins and all unowned
baseline texts/Cabal metadata exact. Generic compiler readers/matchers,eight Rooted positives,all
other binding coordinates and nominal authority axes remain unchanged. All15 binding/signature and
four genuine authority observations match the captured before values. Exact signed empty-ID/frame
reader-then-verifier refusals remain at their original boundary. Full source reversals pass;one type,
two production owners. Phase1 inputs/evidence stay current;no Dockerbase or warm-store input changes.
Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T21:18:01.469935+00:00 to 2026-11-02T21:18:08.437364+00:00,
6.967454 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.62: BuildSourceDigest is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuildSourceDigest its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuildSourceDigest,total buildSourceDigestFromText DATA assignment and ordinary
  buildSourceDigestText elimination. Keep public buildAuthoritySourceDigest returning Text.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer,measurement comparison and authority description.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add raw/constructor/coerce negatives and matching positives for BuildSourceDigest. Its actual raw
  position is the binding source-digest field,not a verifier argument;measure that exact update.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline21:18:08.939305 UTC captures57 texts,958 Haskell files and664 fixtures.
The actual binding source-digest Text field update compiles before edits;the canonical verifier has
no caller-supplied source-digest argument. Generic measureSourceDigest retains its Text result;
explicit role assignment occurs only at the binding and measured-verification boundary. The private
authority retains the role and its existing public source getter remains Text. No source format,
nonempty or provenance validation is introduced. Actual native100-argument pre-edit probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsBuildSourceDigest.hs|2026-11-02T21:18:30.054552+00:00 to2026-11-02T21:18:30.253291+00:00|0.198736|0|
|old-seven-build-axes|2026-11-02T21:18:30.253344+00:00 to2026-11-02T21:18:30.455805+00:00|0.202472|1|
|old-project-position-refusal|2026-11-02T21:18:30.455867+00:00 to2026-11-02T21:18:30.639248+00:00|0.183391|1|
|old-spec-position-refusal|2026-11-02T21:18:30.639301+00:00 to2026-11-02T21:18:30.822254+00:00|0.182963|1|
|compile-binding-show|2026-11-02T21:18:30.822317+00:00 to2026-11-02T21:18:32.732918+00:00|1.910623|0|
|execute-binding-show-signature|2026-11-02T21:18:32.732938+00:00 to2026-11-02T21:18:32.793003+00:00|0.060076|0|
|compile|2026-11-02T21:18:33.101940+00:00 to2026-11-02T21:18:35.036065+00:00|1.934134|0|
|execute|2026-11-02T21:18:35.036083+00:00 to2026-11-02T21:18:35.104681+00:00|0.068608|0|

Raw source field proof SHA6834e16b88017dba2e61c329cf10ad3c70a0da36813de0a1bcca36fc285796e1.
The old build escape retains all seven nominal reasons;old raw project/spec each retain one intended
refusal. The lawful binding witness96c535d04c34b9c7acf15d3956739d3fb83674f493208eb04bf49a8ab6be9258
retains15 actual wire/Show/signature observations and independent171-byte digest
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
The genuine authority before witness49be76a8838d0fb94eb71fd5e2cdb90cb56c33889f048807bd6545740318d369
retains frame ImageBuildFrame image-build-container-0,authority BuildInvocationAuthority build-7,
identifier build-7 and source0442fec496cecddecd34f8ac04e9bbd6e2c1f202c605b9fb06c962138ea26472.
Successful probes have empty stderr;all57 source/metadata subjects remain frozen. A Temp-helper
baseline path setup error is corrected before these measured compiler runs;it is no gate evidence.
The measured after-state controls and final static results follow.

Dated2026-11-02 implementation freeze:33 changed nonempty/37 physical production lines across
Build and demo Commands;exactly one descriptive type. Whole-Build preservation reconstructs the
entire file from the baseline with only the declared export/type/field/codec/private-description,
ordinary getter and measured-source comparison assignments. Generic measurement remains Text;
the IO/Either result gains only total role assignment before the existing comparison. The comparison's
error text and expected/actual order remain compatible. Command is unchanged. Full reversals pass
production33/37,tests77/79,docs12/14. Frozen production hashes:
- core/hostbootstrap-core/src/HostBootstrap/Build.hs:bcfbf85e76c3bc6721c2c9d1f58abcc3eb8f37aa7eaec3e7cd0ff25c64c67f7e
- demo/src/HostBootstrapDemo/Commands.hs:3c08d0557e1bbd7e55e67b4b82065c1a5d8d432306cbd9d63b1459b66c9201ce

Preservation proves953 unrelated Haskell files,all664 old fixtures,other96 pins and all961 current
Haskell paths unchanged except the five named owners and three new measured fixtures. Exact reversal
of the new law/assignments/source getter assertion recovers all old BuildAuthoritySpec controls;
removal of the new three diagnostic registrations and public positive recovers all old CompileFailSpec
bytes,including generic readers/matchers. Cabal/project metadata and all unowned baseline texts stay
exact. Declared docs describe only this DATA role and retained measurement/admission behavior.

Actual native100-argument after probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsBuildSourceDigest.hs|2026-11-02T21:19:49.163659+00:00 to2026-11-02T21:19:49.352004+00:00|0.188346|1|
|ConstructBuildSourceDigest.hs|2026-11-02T21:19:49.352059+00:00 to2026-11-02T21:19:49.541594+00:00|0.189544|1|
|CoerceBuildSourceDigest.hs|2026-11-02T21:19:49.541635+00:00 to2026-11-02T21:19:49.735455+00:00|0.193829|1|
|BuildSourceDigestPublicControl.hs|2026-11-02T21:19:49.735496+00:00 to2026-11-02T21:19:49.926005+00:00|0.190519|0|
|EscapeVerifiedBuildInvocation.hs|2026-11-02T21:19:49.926047+00:00 to2026-11-02T21:19:50.139511+00:00|0.213472|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T21:19:50.139552+00:00 to2026-11-02T21:19:50.324016+00:00|0.184474|1|
|compile-Binding|2026-11-02T21:19:50.324163+00:00 to2026-11-02T21:19:52.367378+00:00|2.043238|0|
|execute-Binding|2026-11-02T21:19:52.367398+00:00 to2026-11-02T21:19:52.647173+00:00|0.279787|0|
|compile-Authority|2026-11-02T21:19:52.647266+00:00 to2026-11-02T21:19:55.421487+00:00|2.774247|0|
|execute-Authority|2026-11-02T21:19:55.421506+00:00 to2026-11-02T21:19:55.648319+00:00|0.226825|0|

The identical raw source-field update now fails GHC-83865 at its actual field expression;constructor
request and representation coerce fail GHC-01928/GHC-18872,each with its complete named diagnostic.
Typed factory/getter/field/update and public Text source-description control compiles with empty
stderr. All seven old build reasons and the coordinator's single rank-2 reason remain exact.
Binding witness6c6a565e7db8d4486bd6394192c1489a4f2c866b0a63584a897bbbb7c0488458
and genuine authority witnesse1ac059cc24f23b035fef0f6f079f9ace02b538a1c9a7af6497850688959cd85
both compile/execute0 with empty stderr. All15 binding/Show/signature and four genuine authority
observations equal their captured before values,including the independent171-byte binding literal;
all production/metadata remain frozen. The new DATA law admits empty/arbitrary text without new
format/provenance checks. Actual signed-source tampering,measurement failures and late signed
empty-ID/frame refusals retain their existing runtime controls.

Native core Main passes2026-11-02T21:19:10.351634+00:00 to2026-11-02T21:19:19.480269+00:00,
9.128692 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T21:19:59.010086+00:00 to2026-11-02T21:20:15.467412+00:00,
16.457426 seconds,0/empty stderr,frozen source/metadata.
Native core test compilation passes2026-11-02T21:20:42.330342+00:00 to2026-11-02T21:21:19.479001+00:00,
37.148889 seconds,0/empty stderr,frozen source/metadata,rts_thr.
No base-image or warm-store input changes. Final focused/consumer and all-four static results follow;the phase's own declared closure gate remains separate.

Native demo test compilation passes21:22:02.378933 to21:22:24.473925 UTC in22.095127 seconds,
0/empty stderr,rts_thr,frozen source/metadata. Native completed selections:

|Actual selection|UTC start to end,2026-11-02|Wall seconds|Result|
|---|---|---:|---|
|Direct source/prior coordinate/literal/compiler/swap/escape/inventory/Doc|2026-11-02T21:22:02.661020+00:00 to2026-11-02T21:22:20.296946+00:00|17.636017|43 passed,17.45 reported seconds,parent0;frozen exact|
|Affected BuildAuthoritySpec/CLI/indexed project-plan/Doc|2026-11-02T21:22:20.574265+00:00 to2026-11-02T21:23:29.727270+00:00|69.153416|250 passed,69.04 reported seconds,parent0;frozen exact|
|Actual demo entire test component|2026-11-02T21:22:42.859250+00:00 to2026-11-02T21:22:48.061405+00:00|5.202167|167 passed,5.16 reported seconds,parent0;frozen exact|

Expected existing CLI and demo teardown-refusal diagnostics are retained;the selected tests and parents
pass. Actual demo plan.json and binary are frozen;its optional reported build-info file is absent.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T21:22:23.284465+00:00 to2026-11-02T21:29:00.464671+00:00|397.182687|All3986 passed,344.73 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T21:22:23.303121+00:00 to2026-11-02T21:28:57.452264+00:00|394.151610|All167 passed,1.84 reported seconds; All3986 passed,344.71 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T21:22:23.318057+00:00 to2026-11-02T21:22:24.251517+00:00|0.933447|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T21:22:23.328291+00:00 to2026-11-02T21:22:31.379113+00:00|8.050851|376 passed,6.61 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1087 audited files,961 Haskell paths and95 docs match the retained Linux tree;every full-command
frozen-after check passes. Dated snapshot aggregates:
- all961:3e2058c4edcc276225ca7ae49461efb06f30f05da8244631471ad9a39612c14c
- owned936:9232731ac93d86e0211f5d3a0ddc948e8f234b09ced155d0586a56c6c32f5b7e
- docs95:4521bbde16154c1163122540bd71a7921281f17ac9965418c52262fdf66cf852

Root preservation proves953 unrelated Haskell files,all664 old fixtures,other96 pins and all unowned
baseline texts/Cabal metadata exact. Generic compiler readers/matchers,eight Rooted positives,all
other binding coordinates and nominal authority axes remain unchanged. All15 binding/signature and
four genuine authority observations match the captured before values. Exact signed empty-ID/frame
reader-then-verifier refusals remain at their original boundary. Full source reversals pass;one type,
two production owners. Phase1 inputs/evidence stay current;no Dockerbase or warm-store input changes.
Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T21:29:35.092229+00:00 to 2026-11-02T21:29:41.020361+00:00,
5.928151 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.63: CoordinatorDigest is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only CoordinatorDigest its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract CoordinatorDigest,total coordinatorDigestFromText DATA assignment and ordinary
  coordinatorDigestText elimination.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer,coordinator/signing and verifier input.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add raw/constructor/coerce negatives and matching positives for CoordinatorDigest at the actual
  canonical verifier's fifth input;matching positives also type the field and signing input.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline21:29:41.480947 UTC captures59 texts,961 Haskell files and667 fixtures.
Actual raw coordinator input in the canonical verifier's fifth position compiles before edits.
Role assignment stays total DATA;generic binary measurement and raw coordinator secret-file bytes
remain Text. The direct builder retains the same raw binary observation;the VM builder retains its
independent observation. Only the coordinator binding/signing/verifier boundary is typed.
Related compiler interfaces are exactly the seven-axis escape,coordinator escape,three prior raw
project/spec/config verifier subjects and two-slot digest swap. Their original named reasons remain
owed;coordinator escape wraps only its existing literal,retaining the same rank-2 pure call/result.
The three prior inline public verifier controls adopt only their coordinator input interface.
No generic matcher/compiler-reader,other coordinate,authority nominal role or runtime check changes.

Actual native100-argument pre-edit probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsCoordinatorDigest.hs|2026-11-02T21:30:02.013314+00:00 to2026-11-02T21:30:02.208946+00:00|0.195631|0|
|old-seven-build-axes|2026-11-02T21:30:02.208999+00:00 to2026-11-02T21:30:02.402419+00:00|0.193430|1|
|old-project-position-refusal|2026-11-02T21:30:02.402482+00:00 to2026-11-02T21:30:02.583016+00:00|0.180544|1|
|old-spec-position-refusal|2026-11-02T21:30:02.583071+00:00 to2026-11-02T21:30:02.769997+00:00|0.186938|1|
|RawTextAsBuildConfigDigest.hs|2026-11-02T21:30:02.770056+00:00 to2026-11-02T21:30:02.965028+00:00|0.194982|1|
|SwapBuildDigests.hs|2026-11-02T21:30:02.965085+00:00 to2026-11-02T21:30:03.154618+00:00|0.189546|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T21:30:03.154686+00:00 to2026-11-02T21:30:03.347186+00:00|0.192511|1|
|compile-binding-show|2026-11-02T21:30:03.347250+00:00 to2026-11-02T21:30:05.304661+00:00|1.957437|0|
|execute-binding-show-signature|2026-11-02T21:30:05.304688+00:00 to2026-11-02T21:30:05.356262+00:00|0.051584|0|
|compile|2026-11-02T21:30:05.685765+00:00 to2026-11-02T21:30:07.664837+00:00|1.979081|0|
|execute|2026-11-02T21:30:07.664855+00:00 to2026-11-02T21:30:07.738322+00:00|0.073477|0|

Raw fifth-input proof SHA2d5c494a8e7b57c99fdf35120761588307cf996ae27896d7683c2361370c30b7.
The old build escape has seven nominal errors,coordinator escape one rank-2 error,prior project/spec/
config each one raw-coordinate error,and spec/config swap exactly two distinct positional errors.
The lawful binding witness6c6a565e7db8d4486bd6394192c1489a4f2c866b0a63584a897bbbb7c0488458
retains15 actual wire/Show/signature observations and independent171-byte digest
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
Genuine coordinator/authority witness4bf06060bd11fc514351f27e27fd4fd37abea23fac23ca24dab40ba9ad108e59
captures five actual observations:BuildCoordinator <signing> coordinator-digest,ImageBuildFrame
image-build-container-0,BuildInvocationAuthority build-7,identifier build-7 and source
0442fec496cecddecd34f8ac04e9bbd6e2c1f202c605b9fb06c962138ea26472.
Successful probes have empty stderr;all59 source/metadata subjects remain frozen. Implementation,
after-state controls and all declared static gates remain due.

Dated2026-11-02 implementation freeze:48 changed nonempty/52 physical production lines across
Build,Command and demo Commands;one descriptive type. Whole-file preservation reconstructs all three
production modules through only the declared coordinator role,ordinary text elimination and actual
binding/signing/verifier assignments. Generic binary/source measurement,raw coordinator file text,
the direct builder's same raw bytes and VM builder's independent observation remain byte-identical.
The canonical comparison,signing-key provenance,active MVar bracket,signature domain,all nominal
authority axes and one-use phases retain their contracts. Full reversals pass production48/52,
tests141/143,docs12/14. Frozen production hashes:
- core/hostbootstrap-core/src/HostBootstrap/Build.hs:186e1008b5e9c2053dc4d2af9e51a2dcfd1966fda3981c949f7d477db1257b43
- core/hostbootstrap-core/src/HostBootstrap/Command.hs:a8ce67c310ca003342da8e7fc8364e810c570864fe60d92c3e4ea62ab947f918
- demo/src/HostBootstrapDemo/Commands.hs:8a1ec1940a8372a83dc7a9c5c3b5c933e0cd81e024dc7e6bf12a7348c7f11f48

Preservation proves949 unrelated Haskell files,661 unrelated old fixtures,all964 current Haskell
paths and other96 export pins exact. Six related fixtures equal their measured adopted bytes:only
coordinator interfaces/literal wrapping and now-unused Text imports change;all original call bodies
and distinct reasons remain. Reconstructing the old test owners with their declared assignments,
new DATA law,coordinator display,exact signer mismatch and compiler controls yields exact current
files. Generic compiler readers/matchers,other controls,Cabal/project metadata and every unowned
baseline text remain unchanged. Both docs state only this DATA role and retained trust boundary.
A Temp audit helper's variable collision is corrected through isolated namespaces;no source changes
or test rerun are needed,and its failed helper result is no completion evidence.

Actual native100-argument after probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsCoordinatorDigest.hs|2026-11-02T21:32:50.928319+00:00 to2026-11-02T21:32:51.164890+00:00|0.236571|1|
|ConstructCoordinatorDigest.hs|2026-11-02T21:32:51.164945+00:00 to2026-11-02T21:32:51.389096+00:00|0.224163|1|
|CoerceCoordinatorDigest.hs|2026-11-02T21:32:51.389149+00:00 to2026-11-02T21:32:51.622224+00:00|0.233090|1|
|CoordinatorDigestPublicControl.hs|2026-11-02T21:32:51.622282+00:00 to2026-11-02T21:32:51.901191+00:00|0.278923|0|
|RawTextAsBuildProjectName.hs|2026-11-02T21:32:51.901259+00:00 to2026-11-02T21:32:52.137889+00:00|0.236641|1|
|RawTextAsBuildSpecDigest.hs|2026-11-02T21:32:52.137941+00:00 to2026-11-02T21:32:52.388782+00:00|0.250858|1|
|RawTextAsBuildConfigDigest.hs|2026-11-02T21:32:52.388857+00:00 to2026-11-02T21:32:52.657635+00:00|0.268789|1|
|SwapBuildDigests.hs|2026-11-02T21:32:52.657688+00:00 to2026-11-02T21:32:52.919581+00:00|0.261910|1|
|EscapeVerifiedBuildInvocation.hs|2026-11-02T21:32:52.919657+00:00 to2026-11-02T21:32:53.203133+00:00|0.283488|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T21:32:53.203194+00:00 to2026-11-02T21:32:53.445417+00:00|0.242234|1|
|compile-Binding|2026-11-02T21:32:53.445637+00:00 to2026-11-02T21:32:55.911079+00:00|2.465469|0|
|execute-Binding|2026-11-02T21:32:55.911104+00:00 to2026-11-02T21:32:55.978612+00:00|0.067519|0|
|compile-Authority|2026-11-02T21:32:55.978706+00:00 to2026-11-02T21:32:58.534382+00:00|2.555705|0|
|execute-Authority|2026-11-02T21:32:58.534409+00:00 to2026-11-02T21:32:58.623485+00:00|0.089092|0|

Identical raw fifth-input source now fails GHC-83865 at the coordinator expression. Constructor
request and representation coerce fail GHC-01928/GHC-18872,each with its complete named block.
Matching typed assignment/getter/field/update,fifth verifier input and signing input compile0/empty
stderr. All seven old build nominal reasons and the coordinator's original single rank-2 reason
remain exact. Prior project/spec/config each retain their own single reason;spec/config swap retains
its two separate complete positional reasons. No unrelated type error satisfies a boundary assertion.
Binding witness5d6a29622247b2667e439b9bafb7a63fe19f8d013beda29885d23328d8c6cb60
and genuine coordinator/authority witnesse7630c1177d60448773a24c23cc39b93edecebcc89f054c563da683c996c8b9c
compile/execute0 with empty stderr. All15 wire/Show/signature and five coordinator/authority outputs
match captured before values,including independent171-byte binding bytes and the actual signature.
Frozen production/metadata remain exact. The new DATA law accepts arbitrary/empty text;existing signed
source,empty-ID/frame,key mismatch,one-use and expired-coordinator controls retain their boundaries.

Native core Main passes2026-11-02T21:30:42.255378+00:00 to2026-11-02T21:30:52.434673+00:00,
10.179359 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T21:31:52.321120+00:00 to2026-11-02T21:32:22.143661+00:00,
29.822726 seconds,0/empty stderr,frozen source/metadata.
Native core test compilation passes2026-11-02T21:33:33.859163+00:00 to2026-11-02T21:34:38.696693+00:00,
64.837939 seconds,0/empty stderr,frozen source/metadata,rts_thr.
No Dockerbase or warm-store input changes. Final focused/consumer and all-four static results follow;the phase's own declared closure gate remains separate.

Native demo test compilation passes21:36:25.755042 to21:36:50.238668 UTC in24.483782 seconds,
0/empty stderr,rts_thr,frozen source/metadata. Native completed selections:

|Actual selection|UTC start to end,2026-11-02|Wall seconds|Result|
|---|---|---:|---|
|Direct coordinator/prior coordinate/literal/compiler/swap/escape/inventory/Doc|2026-11-02T21:36:26.130748+00:00 to2026-11-02T21:36:43.184712+00:00|17.054053|48 passed,16.83 reported seconds,parent0;frozen exact|
|Affected BuildAuthoritySpec/CLI/indexed project-plan/Doc|2026-11-02T21:36:43.462749+00:00 to2026-11-02T21:38:30.420784+00:00|106.958690|251 passed,106.83 reported seconds,parent0;frozen exact|
|Actual demo entire test component|2026-11-02T21:37:16.569902+00:00 to2026-11-02T21:37:21.762949+00:00|5.193057|167 passed,5.15 reported seconds,parent0;frozen exact|

Expected existing CLI and demo teardown-refusal diagnostics are retained;the selected tests and parents
pass. Actual demo plan.json and binary are frozen;its optional reported build-info file is absent.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T21:36:53.434549+00:00 to2026-11-02T21:44:41.758351+00:00|468.326730|All3991 passed,394.82 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T21:36:53.434508+00:00 to2026-11-02T21:44:33.037021+00:00|459.605385|All167 passed,2.07 reported seconds; All3991 passed,397.32 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T21:36:53.434679+00:00 to2026-11-02T21:36:54.570910+00:00|1.136214|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T21:36:53.455053+00:00 to2026-11-02T21:37:02.177112+00:00|8.722083|376 passed,7.22 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1090 audited files,964 Haskell paths and95 docs match the retained Linux tree;every full-command
frozen-after check passes. Dated snapshot aggregates:
- all964:e3b7a8ef6d5156e5013e5c40f512d95429dd0655b44f689550e389dc629cb0a5
- owned939:0ecab34aaad953ee83cb57f26ff516f98a038f1848d983d9fc7bdc13dcb1bc56
- docs95:d48b603bc2ad08fcd9295cb8859aaeb26d7cc3aec88b6e6c8dd9fd9739cad44b

Root preservation proves949 unrelated Haskell files,661 unrelated old fixtures and six declared interfaces,other96 pins and all unowned
baseline texts/Cabal metadata exact. Generic compiler readers/matchers,eight Rooted positives,all
other binding coordinates and nominal authority axes remain unchanged. All15 binding/signature and
five genuine coordinator/authority observations match the captured before values. Exact signed empty-ID/frame
reader-then-verifier refusals remain at their original boundary. Full source reversals pass;one type,
three production owners. Phase1 inputs/evidence stay current;no Dockerbase or warm-store input changes.
Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T21:44:59.387190+00:00 to 2026-11-02T21:45:14.529057+00:00,
15.141941 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.64: BuilderDigest is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuilderDigest its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuilderDigest,total builderDigestFromText DATA assignment and ordinary
  builderDigestText elimination. Keep generic measureBinaryDigest returning Text.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer and measurement comparison.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add raw/constructor/coerce negatives and matching positives for BuilderDigest at the actual
  binding's builder-digest field;there is no caller-supplied verifier digest argument.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline21:45:38.158065 UTC captures59 texts,964 Haskell files and670 fixtures.
The actual raw builder-digest field update compiles before edits. The verifier accepts a builder path,
not a caller-supplied builder digest. Generic measureBinaryDigest keeps its Text result;the existing
measurement and binding boundary alone assign the role. The direct binding uses the same raw binary
observation as its coordinator;the VM binding uses its independent remoteDigest. Private authority
storage has no builder descriptor and remains exact,with all six nominal axes unchanged. No validity,
hex,nonempty or provenance check is added. All old compiler fixtures remain byte-identical.

Actual native100-argument pre-edit probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsBuilderDigest.hs|2026-11-02T21:45:53.440754+00:00 to2026-11-02T21:45:53.646881+00:00|0.206125|0|
|old-seven-build-axes|2026-11-02T21:45:53.646938+00:00 to2026-11-02T21:45:53.868451+00:00|0.221524|1|
|old-project-position-refusal|2026-11-02T21:45:53.868518+00:00 to2026-11-02T21:45:54.069589+00:00|0.201082|1|
|old-spec-position-refusal|2026-11-02T21:45:54.069647+00:00 to2026-11-02T21:45:54.266427+00:00|0.196791|1|
|compile-binding-show|2026-11-02T21:45:54.266491+00:00 to2026-11-02T21:45:56.281839+00:00|2.015391|0|
|execute-binding-show-signature|2026-11-02T21:45:56.281888+00:00 to2026-11-02T21:45:56.359806+00:00|0.077928|0|
|compile|2026-11-02T21:45:56.718666+00:00 to2026-11-02T21:45:58.856790+00:00|2.138139|0|
|execute|2026-11-02T21:45:58.856812+00:00 to2026-11-02T21:45:58.944411+00:00|0.087609|0|

Raw field proof SHA4a493968ad9f0647d80335735988cbc1a4d8171f00ef49e51772aac90cf10109.
The old build escape retains seven nominal reasons;prior raw project/spec each retain one intended
reason. Binding witness5d6a29622247b2667e439b9bafb7a63fe19f8d013beda29885d23328d8c6cb60
retains15 actual wire/Show/signature observations and independent171-byte digest
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
Genuine coordinator/authority witnesse7630c1177d60448773a24c23cc39b93edecebcc89f054c563da683c996c8b9c
retains all five prior observations. Successful probes have empty stderr;all59 source/metadata
subjects remain frozen. The measured after-state controls and final static results follow.

Dated2026-11-02 implementation freeze:31 changed nonempty/35 physical production lines across
Build and demo Commands;one descriptive type. Whole-Build reconstruction admits only the declared
export,type,field,codec and fresh binary-comparison role assignment. Generic measureBinaryDigest
retains Text. Command and private authority storage/nominal axes are byte-identical. Demo adds only
the import and two builder assignments:direct coordinatorDigest and independent VM remoteDigest
keep their raw observations. Full reversals pass production31/35,tests72/74,docs12/14.
Frozen production hashes:
- core/hostbootstrap-core/src/HostBootstrap/Build.hs:f431b95a3c2bd46dfb0279c77d7e22258e5a263b91e1b71ac9e93806e95496ee
- demo/src/HostBootstrapDemo/Commands.hs:799e29db5ccd9ba415dd24ebe9e354f48f628dd74bb2c2e49d65bf8b1b1fbc20

Preservation proves959 unrelated Haskell files,all670 old fixtures,other96 pins and all967 current
Haskell paths exact. Removing the new DATA law and four field assignments recovers all old runtime
controls;removing the three new diagnostic registrations and exact public positive recovers all old
CompileFailSpec bytes,including generic readers/matchers and prior interface controls. New fixtures
equal actual measured sources. Cabal/project metadata and all unowned baseline texts remain exact.
Both declared docs describe only this DATA role and unchanged observation/admission contracts.

Actual native100-argument after probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsBuilderDigest.hs|2026-11-02T21:47:15.971991+00:00 to2026-11-02T21:47:16.154384+00:00|0.182393|1|
|ConstructBuilderDigest.hs|2026-11-02T21:47:16.154434+00:00 to2026-11-02T21:47:16.335390+00:00|0.180965|1|
|CoerceBuilderDigest.hs|2026-11-02T21:47:16.335437+00:00 to2026-11-02T21:47:16.528439+00:00|0.193014|1|
|BuilderDigestPublicControl.hs|2026-11-02T21:47:16.528492+00:00 to2026-11-02T21:47:16.722230+00:00|0.193748|0|
|EscapeVerifiedBuildInvocation.hs|2026-11-02T21:47:16.722280+00:00 to2026-11-02T21:47:16.920827+00:00|0.198557|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T21:47:16.920874+00:00 to2026-11-02T21:47:17.101882+00:00|0.181018|1|
|compile-Binding|2026-11-02T21:47:17.102040+00:00 to2026-11-02T21:47:18.895186+00:00|1.793166|0|
|execute-Binding|2026-11-02T21:47:18.895204+00:00 to2026-11-02T21:47:18.948279+00:00|0.053085|0|
|compile-Authority|2026-11-02T21:47:18.948363+00:00 to2026-11-02T21:47:20.748472+00:00|1.800129|0|
|execute-Authority|2026-11-02T21:47:20.748491+00:00 to2026-11-02T21:47:20.807941+00:00|0.059460|0|

Identical raw builder-field update now fails GHC-83865 at the actual field expression;constructor
request and representation coerce fail GHC-01928/GHC-18872,each with its complete named block.
Matching typed factory/getter/field/update compiles0/empty stderr;no extra verifier argument is
invented. Seven old build nominal reasons remain exact and coordinator escape retains one original
rank-2 refusal. Binding witness230f372c6316c34877089ec456b65a319f134e4c61e9781f3c9df61cc1d6b16a
and genuine coordinator/authority witnessc8c7dac64702fe0afefe8bf7c89a2719f762b969f423501c51666be96b856869
compile/execute0 with empty stderr. All15 wire/Show/signature and five coordinator/authority outputs
match captured before values,including independent171-byte binding bytes and actual signature.
All production/metadata stay frozen. The new DATA law admits empty/arbitrary text;all prior signed
builder/source mismatches,measurement failures,empty-ID/frame and one-use authority controls remain.

Native core Main passes2026-11-02T21:46:34.248642+00:00 to2026-11-02T21:46:49.935943+00:00,
15.687398 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T21:47:21.103119+00:00 to2026-11-02T21:47:37.621406+00:00,
16.518389 seconds,0/empty stderr,frozen source/metadata.
The initial native test build21:48:13.797244 to21:48:38.371241 UTC,24.574149 seconds,
exit1,finds six type errors from duplicate factory calls in three new test assignments. Removing
exactly those duplicate test calls changes no production/fixture bytes. The corrected native test
build passes21:49:13.356276 to21:49:22.112798 UTC in8.756575 seconds,0/empty stderr,
rts_thr,frozen source/metadata. The failed result is not completion evidence. No base/warm inputs
change. Final focused/runtime/consumer and all-four results follow;the phase's own declared
closure gate remains separate.

Native demo test compilation passes21:50:31.126318 to21:50:50.019816 UTC in18.893613 seconds,
0/empty stderr,rts_thr,frozen source/metadata. Native completed selections:

|Actual selection|UTC start to end,2026-11-02|Wall seconds|Result|
|---|---|---:|---|
|Direct builder/prior coordinate/literal/compiler/swap/escape/inventory/Doc|2026-11-02T21:50:31.389271+00:00 to2026-11-02T21:50:46.297190+00:00|14.907993|53 passed,14.71 reported seconds,parent0;frozen exact|
|Affected BuildAuthoritySpec/CLI/indexed project-plan/Doc|2026-11-02T21:50:46.572014+00:00 to2026-11-02T21:51:45.663494+00:00|59.091834|252 passed,58.99 reported seconds,parent0;frozen exact|
|Actual demo entire test component|2026-11-02T21:51:35.111265+00:00 to2026-11-02T21:51:40.241126+00:00|5.129872|167 passed,5.10 reported seconds,parent0;frozen exact|

Expected existing CLI and demo teardown-refusal diagnostics are retained;the selected tests and parents
pass. Actual demo plan.json and binary are frozen;its optional reported build-info file is absent.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T21:50:56.244589+00:00 to2026-11-02T21:57:09.523448+00:00|373.281188|All3996 passed,325.89 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T21:50:56.249149+00:00 to2026-11-02T21:57:08.342620+00:00|372.095799|All167 passed,1.70 reported seconds; All3996 passed,327.19 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T21:50:56.272222+00:00 to2026-11-02T21:50:57.154037+00:00|0.881804|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T21:50:56.272067+00:00 to2026-11-02T21:51:03.554698+00:00|7.282659|376 passed,6.12 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1093 audited files,967 Haskell paths and95 docs match the retained Linux tree;every full-command
frozen-after check passes. Dated snapshot aggregates:
- all967:226ea458f13be3f0cc47e91dac6985f9aa6004dbc2d437eccb99ddb7d71ce75a
- owned942:7e0c62fc9bedc413dc067a3e95d840516e47720260e5aff32678f90c10101ce8
- docs95:507684d61c2af69bbe0c8121008ce2e83f31e18a315beca8a650193c223471e5

Root preservation proves959 unrelated Haskell files,all670 old fixtures,other96 pins and all unowned
baseline texts/Cabal metadata exact. Generic compiler readers/matchers,eight Rooted positives,all
other binding coordinates and nominal authority axes remain unchanged. All15 binding/signature and
five genuine coordinator/authority observations match the captured before values. Exact signed empty-ID/frame
reader-then-verifier refusals remain at their original boundary. Full source reversals pass;one type,
two production owners. Phase1 inputs/evidence stay current;no Dockerbase or warm-store input changes.
Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T21:58:08.644998+00:00 to 2026-11-02T21:58:15.155154+00:00,
6.510177 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.65: BuildFrameName is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuildFrameName its own nominal descriptor role across actual inputs and wire occurrences.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuildFrameName,total buildFrameNameFromText DATA assignment and ordinary
  buildFrameNameText elimination. Keep public imageBuildFrameName returning Text.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only this role's actual binding/decoder/renderer,verifier,private frame and phase-authority
  descriptions. Preserve their public Text display/getters and all nominal indices.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add raw/constructor/coerce negatives and matching positives for BuildFrameName at the actual
  binding frame-name field;there is no extra verifier frame argument.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline21:58:15.654400 UTC captures59 texts,967 Haskell files and673 fixtures.
The actual raw frame-name field update compiles before edits;the canonical verifier has no separate
frame-name input. Total DATA assignment preserves arbitrary/empty text. Existing nonempty-frame
verification stays after the identifier check and before source measurement. Public imageBuildFrameName
retains Text output through total elimination;the private frame stores the role. Its four nominal
indices and the invocation authority's six nominal indices remain exact. All old fixtures stay
byte-identical;there is no generic measurement or Command adoption.

Actual native100-argument pre-edit probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsBuildFrameName.hs|2026-11-02T21:59:01.861096+00:00 to2026-11-02T21:59:02.054214+00:00|0.193116|0|
|old-seven-build-axes|2026-11-02T21:59:02.054267+00:00 to2026-11-02T21:59:02.260382+00:00|0.206127|1|
|old-project-position-refusal|2026-11-02T21:59:02.260448+00:00 to2026-11-02T21:59:02.451557+00:00|0.191119|1|
|old-spec-position-refusal|2026-11-02T21:59:02.451612+00:00 to2026-11-02T21:59:02.645100+00:00|0.193499|1|
|compile-binding-show|2026-11-02T21:59:02.645163+00:00 to2026-11-02T21:59:04.491468+00:00|1.846326|0|
|execute-binding-show-signature|2026-11-02T21:59:04.491488+00:00 to2026-11-02T21:59:04.548013+00:00|0.056536|0|
|compile|2026-11-02T21:59:04.847261+00:00 to2026-11-02T21:59:06.720133+00:00|1.872883|0|
|execute|2026-11-02T21:59:06.720151+00:00 to2026-11-02T21:59:06.786695+00:00|0.066555|0|

Raw field proof SHA628f1397b1bfcbf6f5b1742db6dddf34ea8cbad63869da4c72fbd13c5054b571.
Seven old build nominal reasons and prior raw project/spec single reasons remain intact. Binding
witness230f372c6316c34877089ec456b65a319f134e4c61e9781f3c9df61cc1d6b16a
retains15 actual wire/Show/signature observations and independent171-byte digest
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
Genuine coordinator/frame/authority witnessc8c7dac64702fe0afefe8bf7c89a2719f762b969f423501c51666be96b856869
retains all five prior observations. Existing genuine verified-frame tests separately fix the Text
getter to image-build-container-0. Successful probes have empty stderr;all59 source/metadata subjects
remain frozen. The measured after-state controls and final static results follow.

Dated2026-11-02 implementation freeze:37 changed nonempty/41 physical production lines across
Build and demo Commands;one descriptive type. Whole-Build reconstruction permits only the declared
role API,field/codec,private ImageBuildFrame and BuildCommandAuthority descriptions,their ordinary
Text elimination and the existing late frame predicate. Invocation authority storage,all 4/6/3
nominal authority indices and actual one-use state changes stay exact. Command and generic
measurements remain byte-identical. Demo adds only its import and two literal frame assignments.
Full reversals pass production37/41,tests76/78,docs12/14. Frozen production hashes:
- core/hostbootstrap-core/src/HostBootstrap/Build.hs:5cdc479a8c0d58f8d27bf7a547785ebf6d1f693f87fec364631e1e3e979018d4
- demo/src/HostBootstrapDemo/Commands.hs:08649c76207f769532538a2e6c70d55f9d9db56e35865320d9d74aab2cdd3292

Preservation proves962 unrelated Haskell files,all673 old fixtures,other96 pins and all970 current
Haskell paths exact. Removing the DATA law,four field assignments and two measured phase-display
assertions recovers all old runtime tests. Removing three diagnostic registrations and the exact
public positive recovers all old CompileFailSpec bytes,including compiler readers/matchers. New
fixtures equal actual measured sources. Cabal/project metadata and all unowned baseline texts stay
exact;both docs describe only the DATA role and original verification boundary.

Initial native Main compilation21:59:41.853606 to21:59:44.276535 UTC,2.422943 seconds,exit1,
identifies the private phase authority's remaining Text frame description. Retyping that description
and applying total elimination in its existing Show retains its three nominal indices and unchanged
constructor/use-state body. Before the first successful current Main build,a supplementary real
sign/measure/verify/authorize control uses the retained prior compiled library,whose raw frame binding
is still accepted. This is a compiled-before-state compatibility control after source edits,not a
claim that those source edits had already compiled. Witness711f5c2cce6550a43f17720596edeacf44a25e2c456609b7661c65c1120d8cc1
compiles22:01:37.135475 to22:01:39.098434 UTC,1.962969 seconds,and executes22:01:39.098452
to22:01:39.163256 UTC,0.064815 seconds,both0/empty stderr. It retains the prior five outputs and
captures exact BuildCommandAuthority CheckCodePhase image-build-container-0 and BuildCommandAuthority
BuildPhase image-build-container-0. An initial Temp helper layout error and later field-name setup
assertion are corrected before the successful controls;neither is passing evidence.

Actual native100-argument after probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawTextAsBuildFrameName.hs|2026-11-02T22:03:08.207693+00:00 to2026-11-02T22:03:08.393997+00:00|0.186303|1|
|ConstructBuildFrameName.hs|2026-11-02T22:03:08.394050+00:00 to2026-11-02T22:03:08.577203+00:00|0.183163|1|
|CoerceBuildFrameName.hs|2026-11-02T22:03:08.577251+00:00 to2026-11-02T22:03:08.761593+00:00|0.184353|1|
|BuildFrameNamePublicControl.hs|2026-11-02T22:03:08.761640+00:00 to2026-11-02T22:03:08.968080+00:00|0.206451|0|
|EscapeVerifiedBuildInvocation.hs|2026-11-02T22:03:08.968135+00:00 to2026-11-02T22:03:09.165885+00:00|0.197761|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T22:03:09.165934+00:00 to2026-11-02T22:03:09.356701+00:00|0.190777|1|
|compile-Binding|2026-11-02T22:03:09.356857+00:00 to2026-11-02T22:03:11.227416+00:00|1.870583|0|
|execute-Binding|2026-11-02T22:03:11.227439+00:00 to2026-11-02T22:03:11.282811+00:00|0.055382|0|
|compile-Authority|2026-11-02T22:03:11.282898+00:00 to2026-11-02T22:03:13.171744+00:00|1.888867|0|
|execute-Authority|2026-11-02T22:03:13.171762+00:00 to2026-11-02T22:03:13.246071+00:00|0.074320|0|

Identical raw frame-field update now fails GHC-83865 at its actual expression;constructor request
and representation coerce fail GHC-01928/GHC-18872,each with its complete named block. Typed
assignment/getter/field/update and the existing public Text frame description compile0/empty stderr.
Seven old build nominal reasons remain exact and the coordinator retains one original rank-2 refusal.
Binding witnessb4afe44f77dc94cc8e678bceb2b8238a9ef388e1b099e597c0e63189b072b572
and genuine frame/phase-authority witness129bb81a5675d5074cf0425d32d0a387de6c06642ec65aa9ad6cecc02f4f18ba
compile/execute0 with empty stderr. All15 binding wire/Show/signature and seven coordinator/frame/
authority outputs match their captured before values,including independent171-byte literal bytes.
Frozen production/metadata remain exact. Empty/arbitrary frame text remains DATA;the real signed
empty-frame channel still passes decoding and fails only the original verification predicate with
callback0. Identifier-before-frame and frame-before-measurement ordering remains exact.

Native core Main passes2026-11-02T22:01:39.484474+00:00 to2026-11-02T22:01:47.445621+00:00,
7.961195 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T22:02:34.688955+00:00 to2026-11-02T22:02:51.399628+00:00,
16.710777 seconds,0/empty stderr,frozen source/metadata.
Native core test compilation passes2026-11-02T22:04:03.815547+00:00 to2026-11-02T22:04:34.040415+00:00,
30.225058 seconds,0/empty stderr,frozen source/metadata,rts_thr.
No base/warm input changes. Final focused/runtime/consumer and all-four results follow;
the phase's own declared closure gate remains separate.

Native demo test compilation passes22:05:57.301603 to22:06:16.222417 UTC in18.920931 seconds,
0/empty stderr,rts_thr,frozen source/metadata. Native completed selections:

|Actual selection|UTC start to end,2026-11-02|Wall seconds|Result|
|---|---|---:|---|
|Direct frame/prior coordinate/literal/compiler/swap/escape/inventory/Doc|2026-11-02T22:05:57.599277+00:00 to2026-11-02T22:06:14.339884+00:00|16.740692|58 passed,16.51 reported seconds,parent0;frozen exact|
|Affected BuildAuthoritySpec/CLI/indexed project-plan/Doc|2026-11-02T22:06:14.571627+00:00 to2026-11-02T22:07:12.727060+00:00|58.155784|253 passed,58.06 reported seconds,parent0;frozen exact|
|Actual demo entire test component|2026-11-02T22:07:07.505493+00:00 to2026-11-02T22:07:12.637863+00:00|5.132381|167 passed,5.10 reported seconds,parent0;frozen exact|

Expected existing CLI and demo teardown-refusal diagnostics are retained;the selected tests and parents
pass. Actual demo plan.json and binary are frozen;its optional reported build-info file is absent.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T22:06:24.509177+00:00 to2026-11-02T22:12:21.597236+00:00|357.090290|All4001 passed,311.54 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T22:06:24.509818+00:00 to2026-11-02T22:12:20.807282+00:00|356.299692|All167 passed,1.66 reported seconds; All4001 passed,313.93 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T22:06:24.509681+00:00 to2026-11-02T22:06:25.325018+00:00|0.815324|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T22:06:24.518897+00:00 to2026-11-02T22:06:31.680590+00:00|7.161716|376 passed,6.11 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1096 audited files,970 Haskell paths and95 docs match the retained Linux tree;every full-command
frozen-after check passes. Dated snapshot aggregates:
- all970:b47fd57e5dd35cec089a09466b29f4ce4db632e92301969a680a56b88ecb0f6c
- owned945:e8650000b1b693e46971a18bd696411467db7f8af9b7256743921bd1632fb358
- docs95:59cd33e30415b52bffa31fbbffee31f3c0857311665b0340a8cd69e5289b03a6

Root preservation proves962 unrelated Haskell files,all673 old fixtures,other96 pins and all unowned
baseline texts/Cabal metadata exact. Generic compiler readers/matchers,eight Rooted positives,all
other binding coordinates and nominal authority axes remain unchanged. All15 binding/signature and
seven genuine coordinator/frame/phase-authority observations match the captured before values. Exact signed empty-ID/frame
reader-then-verifier refusals remain at their original boundary. Full source reversals pass;one type,
two production owners. Phase1 inputs/evidence stay current;no Dockerbase or warm-store input changes.
Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T22:13:03.416683+00:00 to 2026-11-02T22:13:10.811438+00:00,
7.394782 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.66: BuildSourceRoot is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuildSourceRoot its own nominal descriptor role at the canonical verifier's source-root
path input. This path is not a binding-wire field.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuildSourceRoot,total buildSourceRootFromFilePath DATA assignment and ordinary
  buildSourceRootFilePath elimination. Keep generic measureSourceDigest accepting FilePath.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only the canonical verifier's source-root path input and eliminate it at its actual generic
  source measurement. No binding field or wire bytes carry the measuring root.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add raw/constructor/coerce negatives and matching positives for BuildSourceRoot at canonical input6,
  with prior coordinate roles typed. Adopt only related old verifier interfaces and preserve their
  seven build reasons,three prior raw digest/project reasons,raw coordinator reason and two swap reasons.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline22:13:11.313701 UTC captures60 texts,970 Haskell files and676 fixtures.
The raw FilePath at canonical source-root input6 compiles before edits,with project/spec/config/
coordinator roles already typed. Generic measureSourceDigest keeps its FilePath input and existing
refusals;the path role adds no validation,normalization or provenance claim. It is not a binding-wire
field. Production owners are Build and Command only. Six old verifier fixture interfaces adopt only
source-root input6:seven-axis build escape,three raw project/spec/config subjects,raw coordinator
and spec/config swap. The coordinator escape is unchanged. Four prior inline public verifier controls
adopt the same path interface;all original named refusal reasons remain required.

Actual native100-argument pre-edit probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawFilePathAsBuildSourceRoot.hs|2026-11-02T22:13:54.827745+00:00 to2026-11-02T22:13:55.049836+00:00|0.222082|0|
|old-seven-build-axes|2026-11-02T22:13:55.049891+00:00 to2026-11-02T22:13:55.281830+00:00|0.231950|1|
|old-project-position-refusal|2026-11-02T22:13:55.281906+00:00 to2026-11-02T22:13:55.512253+00:00|0.230361|1|
|old-spec-position-refusal|2026-11-02T22:13:55.512316+00:00 to2026-11-02T22:13:55.719304+00:00|0.207000|1|
|RawTextAsBuildConfigDigest.hs|2026-11-02T22:13:55.719370+00:00 to2026-11-02T22:13:55.946479+00:00|0.227121|1|
|SwapBuildDigests.hs|2026-11-02T22:13:55.946547+00:00 to2026-11-02T22:13:56.170430+00:00|0.223896|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T22:13:56.170494+00:00 to2026-11-02T22:13:56.401505+00:00|0.231022|1|
|RawTextAsCoordinatorDigest.hs|2026-11-02T22:13:56.401565+00:00 to2026-11-02T22:13:56.625926+00:00|0.224373|1|
|compile-binding-show|2026-11-02T22:13:56.626004+00:00 to2026-11-02T22:13:58.945552+00:00|2.319572|0|
|execute-binding-show-signature|2026-11-02T22:13:58.945571+00:00 to2026-11-02T22:13:59.015412+00:00|0.069853|0|
|compile|2026-11-02T22:13:59.392455+00:00 to2026-11-02T22:14:01.882704+00:00|2.490262|0|
|execute|2026-11-02T22:14:01.882725+00:00 to2026-11-02T22:14:01.963123+00:00|0.080408|0|

Raw source-root input proof SHAab81774bc16d02acaedfb62fdc59f0978e0802462c5f28cde4c3e21076403019.
Old build escape has seven nominal reasons;prior project/spec/config/coordinator each keep their
single intended raw-coordinate reason;spec/config swap keeps two separate positional reasons and
coordinator escape its one rank-2 reason. Binding witnessb4afe44f77dc94cc8e678bceb2b8238a9ef388e1b099e597c0e63189b072b572
retains15 actual wire/Show/signature observations and independent171-byte digest
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
Genuine frame/phase-authority witness129bb81a5675d5074cf0425d32d0a387de6c06642ec65aa9ad6cecc02f4f18ba
retains all seven prior observations. Successful probes have empty stderr;all60 source/metadata
subjects remain frozen. The measured after-state controls and final static results follow.

Dated2026-11-02 implementation freeze:21 changed nonempty/25 physical production lines across
Build and Command;one FilePath DATA role. Whole-Build reconstruction permits only its export/API,
canonical input6 and total elimination at the original generic source measurement. Binding fields,
wire/decoder,all authority storage/indices and verification guards/state remain byte-identical.
Command adds only the import and explicit assignment at its actual selected context path;demo source
and generic measurements are unchanged. Full reversals pass production21/25,tests119/121,docs10/12.
Frozen production hashes:
- core/hostbootstrap-core/src/HostBootstrap/Build.hs:fe3bc69a5b440c8b123c1b85c6b3833e410b8f32c420e224e3ca429578e200dc
- core/hostbootstrap-core/src/HostBootstrap/Command.hs:c148010ac0f00d46fb0213474852b1688982679b13556a61920208731f60b172

Preservation proves959 unrelated Haskell files,670 unrelated old fixtures,all973 current Haskell
paths and other96 export pins exact. Six related verifier fixtures receive only their source-root
interface;old call bodies remain exact. Four prior public compiler controls receive only the same
interface. Reconstructing the declared test changes preserves every other runtime/compiler control,
including generic readers/matchers. New fixtures equal actual measured sources;Cabal/project metadata
and all unowned baseline texts remain exact. Both docs state only the path DATA role and unchanged
measurement/refusal contract. A Temp audit replay's stale positive-key reference is corrected before
its successful result;no source changes or test rerun are needed,and failure is no passing evidence.

Actual native100-argument after probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawFilePathAsBuildSourceRoot.hs|2026-11-02T22:16:52.713228+00:00 to2026-11-02T22:16:52.916185+00:00|0.202960|1|
|ConstructBuildSourceRoot.hs|2026-11-02T22:16:52.916249+00:00 to2026-11-02T22:16:53.101878+00:00|0.185640|1|
|CoerceBuildSourceRoot.hs|2026-11-02T22:16:53.101926+00:00 to2026-11-02T22:16:53.286409+00:00|0.184493|1|
|BuildSourceRootPublicControl.hs|2026-11-02T22:16:53.286457+00:00 to2026-11-02T22:16:53.490014+00:00|0.203568|0|
|RawTextAsCoordinatorDigest.hs|2026-11-02T22:16:53.490069+00:00 to2026-11-02T22:16:53.691504+00:00|0.201445|1|
|RawTextAsBuildProjectName.hs|2026-11-02T22:16:53.691556+00:00 to2026-11-02T22:16:53.894887+00:00|0.203341|1|
|RawTextAsBuildSpecDigest.hs|2026-11-02T22:16:53.894936+00:00 to2026-11-02T22:16:54.090975+00:00|0.196050|1|
|RawTextAsBuildConfigDigest.hs|2026-11-02T22:16:54.091026+00:00 to2026-11-02T22:16:54.285362+00:00|0.194346|1|
|SwapBuildDigests.hs|2026-11-02T22:16:54.285412+00:00 to2026-11-02T22:16:54.472471+00:00|0.187070|1|
|EscapeVerifiedBuildInvocation.hs|2026-11-02T22:16:54.472527+00:00 to2026-11-02T22:16:54.677078+00:00|0.204562|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T22:16:54.677133+00:00 to2026-11-02T22:16:54.869499+00:00|0.192377|1|
|compile-Binding|2026-11-02T22:16:54.869719+00:00 to2026-11-02T22:16:56.934211+00:00|2.064516|0|
|execute-Binding|2026-11-02T22:16:56.934235+00:00 to2026-11-02T22:16:56.999361+00:00|0.065137|0|
|compile-Authority|2026-11-02T22:16:56.999469+00:00 to2026-11-02T22:16:59.181940+00:00|2.182495|0|
|execute-Authority|2026-11-02T22:16:59.181964+00:00 to2026-11-02T22:16:59.300508+00:00|0.118556|0|

Identical raw FilePath input6 now fails GHC-83865 with the measured complete [Char]/BuildSourceRoot
mismatch and actual sixth sourceRoot expression. Constructor request and coerce fail GHC-01928/
GHC-18872,with the latter's actual [Char] representation phrase. The typed factory/getter/input and
raw FilePath generic-measurement positive compiles0/empty stderr. Seven old build reasons,four old
project/spec/config/coordinator single-slot reasons,two distinct swap reasons and the original
coordinator rank-2 reason remain exact. No extra error substitutes for an original boundary reason.
Binding witnessb4afe44f77dc94cc8e678bceb2b8238a9ef388e1b099e597c0e63189b072b572
is source-identical to its before form because paths are not wire fields. Authority witness
8c86429701c281b998b1737b8f3fb4bf12ffb7b7e58b4f4efd2da39c389ad05c
adopts only the actual source-root argument. Both compile/execute0 with empty stderr;all15 binding
wire/Show/signature and seven authority observations match captured before values. Independent171-byte
literal binding bytes and actual signature remain exact;production/metadata stay frozen. The DATA law
retains empty,relative,absolute,Windows-style and escaped paths without normalization or validation.
Existing actual missing-source,builder and signed malformed-channel refusals keep their order.

Native core Main passes2026-11-02T22:14:38.254528+00:00 to2026-11-02T22:14:48.513424+00:00,
10.258963 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T22:15:41.883721+00:00 to2026-11-02T22:16:08.944724+00:00,
27.061170 seconds,0/empty stderr,frozen source/metadata.
Native core test compilation passes2026-11-02T22:18:06.881617+00:00 to2026-11-02T22:19:04.965301+00:00,
58.084036 seconds,0/empty stderr,frozen source/metadata,rts_thr.
No base/warm input changes. Final focused/runtime/consumer and all-four results follow;
the phase's own declared closure gate remains separate.

Native demo test compilation passes22:21:01.214118 to22:21:15.913701 UTC in14.699673 seconds,
0/empty stderr,rts_thr,frozen source/metadata. Native completed selections:

|Actual selection|UTC start to end,2026-11-02|Wall seconds|Result|
|---|---|---:|---|
|Direct source-root/prior coordinate/literal/compiler/swap/escape/inventory/Doc|2026-11-02T22:21:01.642705+00:00 to2026-11-02T22:21:20.726057+00:00|19.083447|63 passed,18.80 reported seconds,parent0;frozen exact|
|Affected BuildAuthoritySpec/CLI/indexed project-plan/Doc|2026-11-02T22:21:21.003213+00:00 to2026-11-02T22:22:50.451883+00:00|89.449195|254 passed,89.34 reported seconds,parent0;frozen exact|
|Actual demo entire test component|2026-11-02T22:22:06.982349+00:00 to2026-11-02T22:22:12.173789+00:00|5.191448|167 passed,5.15 reported seconds,parent0;frozen exact|

Expected existing CLI and demo teardown-refusal diagnostics are retained;the selected tests and parents
pass. Actual demo plan.json and binary are frozen;its optional reported build-info file is absent.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T22:21:42.565007+00:00 to2026-11-02T22:28:37.494328+00:00|414.931829|All4006 passed,348.76 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T22:21:42.572848+00:00 to2026-11-02T22:28:30.676121+00:00|408.105740|All167 passed,1.87 reported seconds; All4006 passed,352.14 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T22:21:42.587268+00:00 to2026-11-02T22:21:43.753643+00:00|1.166357|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T22:21:42.623006+00:00 to2026-11-02T22:21:51.537540+00:00|8.914569|376 passed,7.43 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1099 audited files,973 Haskell paths and95 docs match the retained Linux tree;every full-command
frozen-after check passes. Dated snapshot aggregates:
- all973:59686b19d44786107f5036f7f3ced540ae9315e89df6a85a7d3c2fdf05559947
- owned948:0db2b73c0ca0bb6b4363a7e9068c9a07cf45cbc21f78d6621b547e0735cd787e
- docs95:43f2b7496c5ba2221fb379f79fa2e7b24984877713d07e4500d514b856730ce7

Root preservation proves959 unrelated Haskell files,670 unrelated old fixtures and six declared interface adoptions,other96 pins and all unowned
baseline texts/Cabal metadata exact. Generic compiler readers/matchers,eight Rooted positives,all
other binding coordinates and nominal authority axes remain unchanged. All15 binding/signature and
seven genuine coordinator/frame/phase-authority observations match the captured before values. Exact signed empty-ID/frame
reader-then-verifier refusals remain at their original boundary. Full source reversals pass;one type,
two production owners. Phase1 inputs/evidence stay current;no Dockerbase or warm-store input changes.
Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T22:29:28.243171+00:00 to 2026-11-02T22:29:36.395534+00:00,
8.152394 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.67: BuilderPath is a distinct build coordinate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`demo/test/CommandsSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Give only BuilderPath its own nominal descriptor role at canonical verifier input7. This selected
builder path is not a binding-wire field.
This is one new type with at most the three named production owners; runtime authority checks stay
at their existing admission boundary.

#### Deliverables

- Define only abstract BuilderPath,total builderPathFromFilePath DATA assignment and ordinary
  builderPathFilePath elimination. Keep generic measureBinaryDigest accepting FilePath.
  This is role distinction,not validity/provenance/authority. Keep existing id/frame nonempty checks
  at canonical verification in their current order; add no new hex,nonempty or absolute-path rule.
- Retype only canonical builder-path input7 and eliminate it at the existing generic binary
  measurement. Preserve source-root input6 and all binding-wire fields.
  Preserve every other coordinate and the existing authority's nominal axes.
- Adopt only the actual Command verifier call and/or demo's two binding/coordinator routes as
  applicable. Keep generic measurement APIs generic,including accelerator binary measurements.
- Preserve canonical eight-field binding bytes. Capture a lawful independent literal binding
  vector before the first edit; retain source goldens,actual signatures and signed empty-id/frame refusals.
- Wrap measurements at their actual role boundary: direct coordinator/builder may use the same
  bytes; VM builder uses its independent observation. Path roles are not binding-wire fields.
- Adopt only affected compiler interfaces and the owned Build export pin. Preserve all seven
  EscapeVerifiedBuildInvocation.hs nominal reasons; coordinator adoption also retains the original
  EscapeProvisionedBuildCoordinator.hs rank-2 reason. No raw verifier adapter or matcher weakening.
- Add raw/constructor/coerce negatives and matching positives for BuilderPath at actual input7,
  with prior source-root role typed. Adopt only related old verifier interfaces,including the raw
  source-root subject,and preserve all original nominal/single-slot/swap reasons.
  Preserve unrelated fixtures,Rooted positives,descriptive getter/Show behavior and wire controls.

#### Validation

BuildAuthoritySpec checks the owned input/field,independent binding/source vectors,signatures,
ordered mismatches and unchanged genuine signed malformed-channel refusals. CommandsSpec follows
only the actual coordinator adoption.
Add SwapBuildPaths.hs using both real path roles at actual verifier inputs,matching positive and
both complete transposition blocks.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline22:29:36.961324 UTC captures61 texts,973 Haskell files and679 fixtures.
The raw FilePath at canonical builder input7 compiles before edits,with source-root input6 and all
prior coordinate roles typed. Generic measureBinaryDigest remains FilePath -> IO (Either BuildError
Text),including accelerator callers. The builder path adds no binding-wire field,normalization,
validity or provenance rule. Production owners are Build and Command only. Seven old verifier
fixture interfaces adopt only builder input7:build escape,four raw project/spec/config/coordinator
subjects,raw source-root and spec/config swap. Coordinator escape remains byte-identical. Five old
inline public controls adopt only this path interface. New SwapBuildPaths uses actual roles6/7.

Actual native100-argument pre-edit probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawFilePathAsBuilderPath.hs|2026-11-02T22:30:50.715816+00:00 to2026-11-02T22:30:50.888381+00:00|0.172563|0|
|old-seven-build-axes|2026-11-02T22:30:50.888434+00:00 to2026-11-02T22:30:51.072965+00:00|0.184543|1|
|old-project-position-refusal|2026-11-02T22:30:51.073028+00:00 to2026-11-02T22:30:51.253315+00:00|0.180298|1|
|old-spec-position-refusal|2026-11-02T22:30:51.253369+00:00 to2026-11-02T22:30:51.433065+00:00|0.179707|1|
|RawTextAsBuildConfigDigest.hs|2026-11-02T22:30:51.433124+00:00 to2026-11-02T22:30:51.616051+00:00|0.182938|1|
|SwapBuildDigests.hs|2026-11-02T22:30:51.616108+00:00 to2026-11-02T22:30:51.801836+00:00|0.185739|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T22:30:51.801896+00:00 to2026-11-02T22:30:51.982939+00:00|0.181054|1|
|RawTextAsCoordinatorDigest.hs|2026-11-02T22:30:51.982997+00:00 to2026-11-02T22:30:52.165047+00:00|0.182061|1|
|RawFilePathAsBuildSourceRoot.hs|2026-11-02T22:30:52.165105+00:00 to2026-11-02T22:30:52.354985+00:00|0.189892|1|
|compile-binding-show|2026-11-02T22:30:52.355049+00:00 to2026-11-02T22:30:54.196404+00:00|1.841376|0|
|execute-binding-show-signature|2026-11-02T22:30:54.196423+00:00 to2026-11-02T22:30:54.249847+00:00|0.053434|0|
|compile|2026-11-02T22:30:54.552127+00:00 to2026-11-02T22:30:56.416802+00:00|1.864686|0|
|execute|2026-11-02T22:30:56.416822+00:00 to2026-11-02T22:30:56.486732+00:00|0.069918|0|

Raw builder input proof SHA6ce6f318f1d0267c8ace152fc5b235a839f53bb7c8c2e830e23bfcc327a1f9da.
Old build escape retains seven nominal reasons;project/spec/config/coordinator/source-root retain
five single-slot reasons,spec/config swap two distinct reasons and coordinator escape one rank-2
reason. Binding witnessb4afe44f77dc94cc8e678bceb2b8238a9ef388e1b099e597c0e63189b072b572
retains15 actual wire/Show/signature observations and independent171-byte digest
fb2453ceb09a0511d9761bc178c4c9487bf3c027b85e81549af6183feea2bd54.
Genuine authority witness8c86429701c281b998b1737b8f3fb4bf12ffb7b7e58b4f4efd2da39c389ad05c
retains seven observations. Successful probes have empty stderr;all61 source/metadata subjects stay
frozen. The measured after-state controls and final static results follow.

Dated2026-11-02 implementation freeze:21 changed nonempty/25 physical production lines across
Build and Command;one FilePath DATA role. Whole-Build reconstruction permits only its export/API,
canonical input7 and total elimination at the existing generic binary measurement. Source-root
input6,all binding/wire/decoder bytes and authority storage/indices/guards/state remain exact.
Command adds only the import and explicit assignment at its existing executable path;demo source
and generic measurements remain unchanged. Full reversals pass production21/25,tests140/142,
docs11/13. Frozen production hashes:
- core/hostbootstrap-core/src/HostBootstrap/Build.hs:79c9b8b21c51463f5fd8b0fbdb7056ce2fec099de506d9148ab54846664d72ed
- core/hostbootstrap-core/src/HostBootstrap/Command.hs:28a9b60282fbd18b34ba47fe0873eca0342d4dc1ada34d34336500eeb2e4798e

Preservation proves961 unrelated Haskell files,672 unrelated old fixtures,all977 current Haskell
paths and other96 export pins exact. Seven related fixtures receive only builder input7 interfaces;
all original call bodies remain exact. Five prior public controls adopt only the same interface.
Reconstructing the declared test additions preserves every other runtime/compiler control,including
generic readers/matchers. Four new fixtures equal measured sources;Cabal/project metadata and every
unowned baseline text stay exact. Both docs state only the path DATA role and retained measurement
contract. No path validation,normalization,origin claim or wire field is introduced.

Actual native100-argument after probes:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|RawFilePathAsBuilderPath.hs|2026-11-02T22:33:12.879744+00:00 to2026-11-02T22:33:13.077138+00:00|0.197396|1|
|ConstructBuilderPath.hs|2026-11-02T22:33:13.077201+00:00 to2026-11-02T22:33:13.282575+00:00|0.205385|1|
|CoerceBuilderPath.hs|2026-11-02T22:33:13.282630+00:00 to2026-11-02T22:33:13.508916+00:00|0.226298|1|
|SwapBuildPaths.hs|2026-11-02T22:33:13.508971+00:00 to2026-11-02T22:33:13.742365+00:00|0.233405|1|
|BuilderPathPublicControl.hs|2026-11-02T22:33:13.742415+00:00 to2026-11-02T22:33:13.969045+00:00|0.226640|0|
|RawFilePathAsBuildSourceRoot.hs|2026-11-02T22:33:13.969094+00:00 to2026-11-02T22:33:14.189296+00:00|0.220212|1|
|RawTextAsCoordinatorDigest.hs|2026-11-02T22:33:14.189349+00:00 to2026-11-02T22:33:14.408143+00:00|0.218806|1|
|RawTextAsBuildProjectName.hs|2026-11-02T22:33:14.408195+00:00 to2026-11-02T22:33:14.643611+00:00|0.235427|1|
|RawTextAsBuildSpecDigest.hs|2026-11-02T22:33:14.643666+00:00 to2026-11-02T22:33:14.852463+00:00|0.208808|1|
|RawTextAsBuildConfigDigest.hs|2026-11-02T22:33:14.852519+00:00 to2026-11-02T22:33:15.067124+00:00|0.214616|1|
|SwapBuildDigests.hs|2026-11-02T22:33:15.067173+00:00 to2026-11-02T22:33:15.273597+00:00|0.206436|1|
|EscapeVerifiedBuildInvocation.hs|2026-11-02T22:33:15.273652+00:00 to2026-11-02T22:33:15.512261+00:00|0.238620|1|
|EscapeProvisionedBuildCoordinator.hs|2026-11-02T22:33:15.512312+00:00 to2026-11-02T22:33:15.735234+00:00|0.222933|1|
|compile-Binding|2026-11-02T22:33:15.735622+00:00 to2026-11-02T22:33:17.998711+00:00|2.263112|0|
|execute-Binding|2026-11-02T22:33:17.998731+00:00 to2026-11-02T22:33:18.103057+00:00|0.104340|0|
|compile-Authority|2026-11-02T22:33:18.103177+00:00 to2026-11-02T22:33:20.351096+00:00|2.247944|0|
|execute-Authority|2026-11-02T22:33:20.351126+00:00 to2026-11-02T22:33:20.420108+00:00|0.068993|0|

Identical raw FilePath input7 now fails GHC-83865 with the complete measured [Char]/BuilderPath
mismatch at builder. Constructor request and coerce fail GHC-01928/GHC-18872 with their full named
phrases. The new actual-role SwapBuildPaths yields exactly two separate GHC-83865 blocks:expected
BuildSourceRoot/actual BuilderPath at input6,and expected BuilderPath/actual BuildSourceRoot at7.
Matching ordered-role positive,factory/getter and raw generic binary-measurement signature compile
0/empty stderr. Seven old build reasons,five old project/spec/config/coordinator/source-root reasons,
two old digest-swap reasons and the original coordinator rank-2 reason remain exact. Source-root's
complete primary including Expected/Actual is compared directly,so a new builder error cannot mask it.
Binding witnessb4afe44f77dc94cc8e678bceb2b8238a9ef388e1b099e597c0e63189b072b572
is source-identical to before because paths are not wire fields. Authority witness
de2ac5c0ecd3f53e8c0cc71d00ea2caecd19a99a1dbf8c06296ca28def0d46dd
adopts only builder argument7. Both compile/execute0 with empty stderr;all15 binding wire/Show/
signature and seven authority outputs match captured before values,including independent171-byte
literal binding bytes. Frozen source/metadata stay exact. The DATA law retains empty,relative,
absolute,Windows-style and escaped paths;existing real filesystem and malformed-channel cases retain
measurement and refusal order. No raw production verifier adapter or generic matcher changes occur.

Native core Main passes2026-11-02T22:31:18.612379+00:00 to2026-11-02T22:31:34.527376+00:00,
15.915089 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T22:31:55.399876+00:00 to2026-11-02T22:32:13.293100+00:00,
17.893330 seconds,0/empty stderr,frozen source/metadata.
Native core test compilation passes2026-11-02T22:34:17.806836+00:00 to2026-11-02T22:35:24.783682+00:00,
66.977250 seconds,0/empty stderr,frozen source/metadata,rts_thr.
No base/warm input changes. Final focused/runtime/consumer and all-four results follow;
the phase's own declared closure gate remains separate.

Native demo test compilation passes22:38:14.248334 to22:38:31.768747 UTC in17.520517 seconds,
0/empty stderr,rts_thr,frozen source/metadata. Native completed selections:

|Actual selection|UTC start to end,2026-11-02|Wall seconds|Result|
|---|---|---:|---|
|Direct builder-path/prior coordinate/literal/compiler/swap/escape/inventory/Doc|2026-11-02T22:38:14.694518+00:00 to2026-11-02T22:38:36.245873+00:00|21.551466|69 passed,21.27 reported seconds,parent0;frozen exact|
|Affected BuildAuthoritySpec/CLI/indexed project-plan/Doc|2026-11-02T22:38:36.543937+00:00 to2026-11-02T22:40:17.858039+00:00|101.314700|255 passed,101.19 reported seconds,parent0;frozen exact|
|Actual demo entire test component|2026-11-02T22:39:45.799097+00:00 to2026-11-02T22:39:50.986907+00:00|5.187809|167 passed,5.15 reported seconds,parent0;frozen exact|

Expected existing CLI and demo teardown-refusal diagnostics are retained;the selected tests and parents
pass. Actual demo plan.json and binary are frozen;its optional reported build-info file is absent.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T22:39:06.090493+00:00 to2026-11-02T22:46:24.640424+00:00|438.552580|All4012 passed,362.01 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T22:39:06.092944+00:00 to2026-11-02T22:46:14.378199+00:00|428.287844|All167 passed,2.29 reported seconds; All4012 passed,363.59 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T22:39:06.097235+00:00 to2026-11-02T22:39:07.141686+00:00|1.044431|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T22:39:06.130343+00:00 to2026-11-02T22:39:15.374919+00:00|9.244611|376 passed,7.75 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1103 audited files,977 Haskell paths and95 docs match the retained Linux tree;every full-command
frozen-after check passes. Dated snapshot aggregates:
- all977:27605ef1032829f3c9c7ea3da73f7f06c9b47c4c43519a6cbaa0737a474de080
- owned952:857852a685c132378af124a26e85b5e93ab2fc5f55ed8ecd4c7f46593d60c18e
- docs95:15545d1438819552a47413df5c3097274d572c27a44ec1f4cb883ca42e3a6c41

Root preservation proves961 unrelated Haskell files,672 unrelated old fixtures and seven declared interface adoptions,other96 pins and all unowned
baseline texts/Cabal metadata exact. Generic compiler readers/matchers,eight Rooted positives,all
other binding coordinates and nominal authority axes remain unchanged. All15 binding/signature and
seven genuine coordinator/frame/phase-authority observations match the captured before values. Exact signed empty-ID/frame
reader-then-verifier refusals remain at their original boundary. Full source reversals pass;one type,
two production owners. Phase1 inputs/evidence stay current;no Dockerbase or warm-store input changes.
Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own declared
closure gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T22:47:22.173684+00:00 to 2026-11-02T22:47:28.198992+00:00,
6.025324 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.68: Build hashes through Digest [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Adopt one actual owner's canonical hashing/framing implementation. This is one owner adoption
with unchanged bytes and no new contract/type.

#### Deliverables

- Import canonical sha256Hex and delete only Build's duplicate. Generic measurement contracts stay.
- Keep Ed25519 convert; remaining bit operations are Windows-only name handling,so scope those
  imports to their actual CPP row without warning suppression.
- Preserve source/binding/signature vectors,typed roles and authority tests; adopt no other owner.

#### Validation

BuildAuthoritySpec,HandoffSpec and ActivationSpec retain independent byte/signature controls and
positively named subjects. Remove only this owner's now-gone legacy row after actual validation.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline22:47:28.693594 UTC captures63 texts,977 Haskell files and683 fixtures.
The canonical owner is HostBootstrap.Digest in the existing ownership-internal unit;Main already
depends on that unit,so no Cabal edge is added. Build's complete private sha256Hex type/definition is
byte-identical to the canonical definition,measured SHA09dc390229b483c15bfa65996444e6690ffaa593a5e3ec1409f55884c415eaca.
Only Build adopts the owner. Ed25519's unqualified convert stays;the hash-only Crypto.Hash,qualified
ByteArray and ByteString.Char8 imports disappear. Remaining bit operations are in the actual Windows
metadata/WTF-8 branch,so their complete import sits inside mingw32_HOST_OS. No authority,role,
measurement,wire or export-list change is introduced. The legacy Build row stays until actual focused
validation;only that row is removed before final all-four validation.

Actual native100-argument before controls:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|compile-Binding|2026-11-02T22:49:28.673999+00:00 to2026-11-02T22:49:31.120642+00:00|2.446645|0|
|execute-Binding|2026-11-02T22:49:31.120665+00:00 to2026-11-02T22:49:31.205598+00:00|0.084941|0|
|compile-Authority|2026-11-02T22:49:31.205689+00:00 to2026-11-02T22:49:33.627479+00:00|2.421818|0|
|execute-Authority|2026-11-02T22:49:33.627507+00:00 to2026-11-02T22:49:33.748803+00:00|0.121310|0|

Binding witnessb4afe44f77dc94cc8e678bceb2b8238a9ef388e1b099e597c0e63189b072b572
retains15 actual wire/Show/signature observations,including the independent171-byte literal vector.
Genuine authority/binary witness7adeee553ab557ef6a9e38097e75a74d9eff7f6e840727f195bc415fdef29a7a
retains seven prior authority observations and independently checks measured builder bytes against
Python SHA-256 of literal hex6275696c646572206279746573,digest
f1d5b07b9dc7eeaa7ad078831af731a67396636e9815ec78f090ed236e2edd01.
Both compile and execute0 with empty stderr;all63 source/metadata subjects remain frozen. Adoption,
after-state controls,focused validation,owned ledger removal and all-four static results remain due.

Dated2026-11-02 Build adoption imports HostBootstrap.Digest.sha256Hex and removes only the exact
duplicate definition and its hash-only imports. Data.ByteArray.convert remains for Ed25519. All
remaining bit operators are imported in the actual Windows CPP branch,whose metadata/WTF-8 bodies
are unchanged. No new type,public export,Cabal edge,measurement or authority contract is introduced.
The component map describes Build's actual canonical hash reuse and retained source measurement.
The owned legacy row remains until the following actual focused validation passes.

Actual native100-argument after controls use source-identical witnesses:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|compile-Binding|2026-11-02T22:52:15.679642+00:00 to2026-11-02T22:52:17.268832+00:00|1.589198|0|
|execute-Binding|2026-11-02T22:52:17.268851+00:00 to2026-11-02T22:52:17.321180+00:00|0.052339|0|
|compile-Authority|2026-11-02T22:52:17.321268+00:00 to2026-11-02T22:52:18.955224+00:00|1.633974|0|
|execute-Authority|2026-11-02T22:52:18.955242+00:00 to2026-11-02T22:52:19.019733+00:00|0.064501|0|

All15 binding wire/Show/signature and eight authority/binary observations equal their captured
before values. The actual measured builder digest equals independent SHA-256 of the fixed builder
bytes;source and signature controls remain exact. Every successful compile/execute has empty stderr;
all63 source/metadata subjects stay frozen.
Native core Main passes2026-11-02T22:50:57.193678+00:00 to2026-11-02T22:51:15.501282+00:00,
18.307714 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T22:51:53.453896+00:00 to2026-11-02T22:52:05.725076+00:00,
12.271253 seconds,0/empty stderr,frozen source/metadata.
Native core test compilation passes2026-11-02T22:52:19.342820+00:00 to2026-11-02T22:52:28.303858+00:00,
8.961093 seconds,0/empty stderr,frozen source/metadata,rts_thr.
Focused BuildAuthoritySpec/HandoffSpec/ActivationSpec/Doc validation,owned ledger removal and
all-four static results remain due. No base/warm input changes occur.

The actual focused BuildAuthoritySpec/HandoffSpec/ActivationSpec/Doc selection passes321 cases
2026-11-02T22:54:40.359625+00:00 to2026-11-02T22:55:28.729390+00:00,48.26 reported/48.370043 wall seconds,parent0/
empty stderr,frozen sources/binary/compiler metadata. Native Build Windows name controls run their
actual supported case;the three POSIX cases report their exact measured Unsupported capability row.
Only after that terminal pass,the single Build ledger row is removed at 2026-11-02T22:56:57.360224+00:00;the exact row is
saved outside the repository and every other ledger byte,including Handoff/Activation rows,stays
unchanged. No completion claim is made from a source-only check. The component map's Build hash
statement is current. Final preservation and all-four static results follow.

Final source audit passes13 changed nonempty/14 physical production lines in Build only,zero test
changes and three changed documentation lines. Build SHA3fbcdbebad5d987da05c5fa61d1b5bdce303167ed1b3a43e973852500468696b.
All977 Haskell paths,other976 Haskell files,all683 compiler fixtures,all tests and97 export pins remain
exact. Full-Build reconstruction proves only the declared canonical-hash/import adoption;Ed25519
convert,Windows metadata/name bodies,all typed roles,authority/measurement/wire code,Cabal/project
metadata and unowned baseline texts are byte-identical. Canonical Digest itself is unchanged.
The component map changes only its owned Build hash clause;ledger changes only the validated Build
row. Every other ledger byte remains exact. LF and scoped diff checks pass. The production change
adds no type or package edge and changes no base/warm input. Final all-four static results follow.

Actual native demo test compilation passes22:54:40.149657 to22:54:52.395332 UTC,12.245747
seconds,0/empty stderr,rts_thr,frozen source/metadata. All167 native demo tests pass
2026-11-02T22:59:34.295030+00:00 to2026-11-02T22:59:39.438877+00:00,5.12 reported/5.143861 wall seconds,
parent0,frozen source/binary/actual plan.json metadata. Its optional reported build-info file is absent.
Expected existing teardown-refusal diagnostics remain;the actual suite and parent pass.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end,2026-11-02|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T22:59:34.154804+00:00 to2026-11-02T23:06:15.667123+00:00|401.514750|All4012 passed,381.58 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T22:59:34.154634+00:00 to2026-11-02T23:06:10.392285+00:00|396.240049|All167 passed,1.45 reported seconds; All4012 passed,379.58 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T22:59:34.157034+00:00 to2026-11-02T22:59:35.093302+00:00|0.936257|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T22:59:34.178659+00:00 to2026-11-02T22:59:41.262602+00:00|7.083970|376 passed,5.87 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1103 audited files,977 Haskell paths and95 docs match the retained Linux tree;all full-command
frozen-after checks pass. Dated aggregate digests:
- all977:23a4d98657862307b90fd71df80422b2eaf42ee0d0f7b1c629638227e2ac896a
- owned952:61ce3155d42918f98f8fe22385ec5b085f2131cdae45b089cd8ded78451b9072
- docs95:4a23ce7bcd85887031eb639372218674cace04493829dc42984680908767cff0

All976 unrelated Haskell files,683 compiler fixtures,all tests and97 export pins remain exact.
Only Build imports the canonical hash;Ed25519 convert and actual Windows name handling remain.
Source/binding/signature goldens,all23 actual observations,role/authority contracts and package edges
retain their subjects. Only the validated Build ledger row is removed,after the321-case focused pass;
all other ledger bytes stay exact. Full baseline reversals pass production13/14 lines,tests0,docs3;
no new type. Phase1 inputs/evidence remain current. No base/warm inputs change. Provider-live is not
requested/Unsupported;no live-substrate claim is made. The phase's own declared gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T23:07:14.584409+00:00 to 2026-11-02T23:07:23.236947+00:00,
8.652567 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.69: Handoff frames and hashes through Digest [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Adopt one actual owner's canonical hashing/framing implementation. This is one owner adoption
with unchanged bytes and no new contract/type.

#### Deliverables

- Import/value-reexport canonical frameWire with the existing export spelling; remove only local
  frameWire/digestBytes and use canonical sha256Hex for childConfigDigest/recoveryWireDigest.
  Keep word64BigEndian for version/generation words.
- Preserve all five fixed bundles,119-line/6323-byte response,thirteen readers,capability/path and
  Relay4292. Adopt only the two HandoffSpec digestBytes strings; no whole-file/complement rehash.
- Use existing ownership-internal dependency; no Cabal edge or public module reexport is added.

#### Validation

BuildAuthoritySpec,HandoffSpec and ActivationSpec retain independent byte/signature controls and
positively named subjects. Remove only this owner's now-gone legacy row after actual validation.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline23:07:23.823129 UTC captures63 texts,977 Haskell files and683 fixtures.
Only Handoff adopts canonical frameWire/sha256Hex through its existing ownership-internal dependency.
The frameWire export spelling remains a value reexport;no public module export or package edge is
added. Local frameWire/digestBytes implementations and hash-only imports disappear;all seven private
digestBytes call sites use sha256Hex. Ed25519 convert and word64BigEndian/version/generation words
stay. Only two HandoffSpec source strings naming digestBytes adopt the canonical name;all helpers,
frozen expected values and positively named subjects remain unchanged.

Actual native100-argument before controls:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|compile-Binding|2026-11-02T23:14:01.632851+00:00 to2026-11-02T23:14:03.530420+00:00|1.897579|0|
|execute-Binding|2026-11-02T23:14:03.530444+00:00 to2026-11-02T23:14:03.587892+00:00|0.057459|0|
|compile-Authority|2026-11-02T23:14:03.587985+00:00 to2026-11-02T23:14:05.526631+00:00|1.938671|0|
|execute-Authority|2026-11-02T23:14:05.526656+00:00 to2026-11-02T23:14:05.587296+00:00|0.060651|0|
|compile-HandoffData|2026-11-02T23:14:05.587375+00:00 to2026-11-02T23:14:07.385376+00:00|1.798028|0|
|execute-HandoffData|2026-11-02T23:14:07.385403+00:00 to2026-11-02T23:14:07.439881+00:00|0.054489|0|
|compile-HandoffBundles|2026-11-02T23:14:07.439966+00:00 to2026-11-02T23:14:11.224992+00:00|3.785060|0|
|execute-HandoffBundles|2026-11-02T23:14:11.225037+00:00 to2026-11-02T23:14:11.532446+00:00|0.307426|0|

The23 prior binding/signature/authority/binary observations remain exact. Four actual frame/hash
vectors use empty,0/1/127/128/255,all256 byte values and257 FF bytes;their actual length-prefix bytes,
child/recovery SHA-256 digests and roundtrip results equal independent Python unsigned64-big-endian
and SHA-256 calculations. Actual SourceGuard.haskellDefinitionClauseTokens captures complete named
entries and Aeson-serialized bytes for five existing subjects;their fixed hashes remain:
- request:81d964e757a7b2fdcb1b706ed37624d546b73144c28553d8663f282f98e26426
- response-framing:3e4758bcc69e72989965d4ea8c85197a4299ca4ee2ead60db7a1c848067e78b5
- response-auth:d00bda468053456e2c343643f67eb8a57ee5272bd516e2fbbcd1f74a47fdb1ea
- scope-auth:621e82df4064acb7a5d6cffd852c253626da4626003754613c4a7217f0d7b037
- payload-recovery:fe95ce390d386f779e420f4e5f851ddbafb2ff0c9047fe3d4f681eed33f9c88f

The actual rooted-response region remains6323 bytes with literal digest
8017cb84eb922ba3448e54e5fa33ed1d825798089fe7190d52842a0e9827fe69.
Existing119-line,thirteen-reader,capability/path and Relay4292 controls remain required. Successful
compiles/executes have empty stderr;all63 source/metadata subjects stay frozen. An initial Windows
llvm resource rename failure is resolved with isolated child TEMP/TMP/TMPDIR and -tmpdir. The bundle
probe explicitly lists actual SourceGuard.hs as a home-module target to retain -Wmissing-home-modules
under Werror;its initial omitted-target refusal is not passing evidence. No warning policy is weakened.
The dated after-state and final validation follow.

Dated2026-11-02 Handoff adoption imports canonical frameWire and sha256Hex through the existing
ownership-internal dependency. The public frameWire export is the same bare value spelling;there is
no module reexport or new edge. Both local implementations and hash-only imports are removed;all
seven private digestBytes uses select canonical sha256Hex. Ed25519 convert,word64BigEndian and all
version/generation uses remain. HandoffSpec changes only its two complete source-assertion strings,
retaining their predicates and every fixed expectation. An initial inventory assertion found seven
uses before production writes;its unchanged-tree Cabal result is not adoption evidence.

Actual native100-argument after controls use source-identical witnesses and the same explicit
SourceGuard home target,isolated compiler temporary directory and warning policy:

|Actual subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|compile-Binding|2026-11-02T23:17:39.606413+00:00 to2026-11-02T23:17:41.456993+00:00|1.850588|0|
|execute-Binding|2026-11-02T23:17:41.457014+00:00 to2026-11-02T23:17:41.529298+00:00|0.072295|0|
|compile-Authority|2026-11-02T23:17:41.529395+00:00 to2026-11-02T23:17:43.450234+00:00|1.920872|0|
|execute-Authority|2026-11-02T23:17:43.450267+00:00 to2026-11-02T23:17:43.521826+00:00|0.071571|0|
|compile-HandoffData|2026-11-02T23:17:43.521924+00:00 to2026-11-02T23:17:45.337398+00:00|1.815496|0|
|execute-HandoffData|2026-11-02T23:17:45.337422+00:00 to2026-11-02T23:17:45.399320+00:00|0.061909|0|
|compile-HandoffBundles|2026-11-02T23:17:45.399421+00:00 to2026-11-02T23:17:49.271498+00:00|3.872111|0|
|execute-HandoffBundles|2026-11-02T23:17:49.271545+00:00 to2026-11-02T23:17:49.586078+00:00|0.314547|0|

All23 binding/signature/authority/binary observations and four independent frame/hash vectors equal
before values. All five complete positively named declaration lists,their clause-token entries and
actual Aeson bytes are identical;the five original expected hashes stay unchanged. The raw rooted
response region remains exactly6323 bytes,hex-identical to before with its original8017cb84 digest.
No complement,whole-file freeze or expected-hash rebase substitutes for these actual subjects.
All successful compiles/executes have empty stderr;all63 source/metadata subjects remain frozen.
Native core Main passes2026-11-02T23:16:00.961975+00:00 to2026-11-02T23:16:26.121544+00:00,
25.159726 seconds,0/empty stderr,frozen source/metadata.
Native demo Main passes2026-11-02T23:16:58.384846+00:00 to2026-11-02T23:17:33.009525+00:00,
34.624895 seconds,0/empty stderr,frozen source/metadata.
The component map records only this actual canonical Handoff reuse. Existing119-line,thirteen-reader,
capability/path,Relay4292 and all private package/module controls are held by the actual suites below.
The Handoff legacy row is removed after the focused pass below;no other owner's row changes.
No base/warm input changes occur. Focused and all-four static results follow.

The actual focused BuildAuthoritySpec/HandoffSpec/ActivationSpec/Doc selection passes321 cases
2026-11-02T23:21:44.713567+00:00 to2026-11-02T23:22:41.382964+00:00,56.52 reported/56.669736 wall seconds,parent0/
empty stderr,frozen sources/binary/compiler metadata. Native Build Windows name controls run their
actual supported case;the three POSIX cases report their exact measured Unsupported capability row.
Only after that terminal pass,the single Handoff ledger row is removed at 2026-11-02T23:22:50.046353+00:00;the exact row is
saved outside the repository and every other ledger byte,including Activation rows,stays
unchanged. No completion claim is made from a source-only check. The component map's Handoff framing/hash
statement is current. Final preservation and all-four static results follow.

Actual native core test compilation passes2026-11-02T23:19:03.500905+00:00 to2026-11-02T23:20:30.851075+00:00,
87.350718 seconds,0/empty stderr,rts_thr,frozen source/metadata.
Actual native demo test compilation passes2026-11-02T23:21:44.494089+00:00 to2026-11-02T23:22:06.959767+00:00,
22.465816 seconds,0/empty stderr,rts_thr,frozen source/metadata.
Full baseline source reversals pass:production32 nonempty/34 physical lines in Handoff only;
tests4/4 lines are exactly two owned digest-name assertions;docs3/3 lines. All975 other Haskell
files,all977 paths and683 compiler fixtures remain exact. Every unowned captured text,Cabal edge,
canonical Digest,Ed25519 convert,word64 encoding and other ledger byte is unchanged. Scoped diff
checks pass and text stays LF. These static checks make no runtime claim;the focused321 pass above
and final all-four commands supply actual execution evidence.

All167 actual native demo tests pass2026-11-02T23:23:53.772978+00:00 to2026-11-02T23:23:58.883690+00:00,
5.09 reported/5.110729 wall seconds,parent0,frozen source/binary/actual plan.json.
The optional reported build-info file is absent;actual metadata is frozen. Existing teardown-refusal
diagnostics remain;the actual suite and parent pass.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T23:24:08.493899+00:00 to2026-11-02T23:32:11.486886+00:00|482.996013|All4012 passed,367.19 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T23:24:08.493813+00:00 to2026-11-02T23:32:10.997316+00:00|482.506526|All167 passed,1.50 reported seconds; All4012 passed,370.18 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T23:24:08.493720+00:00 to2026-11-02T23:24:09.231234+00:00|0.737500|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T23:24:08.493565+00:00 to2026-11-02T23:24:15.295675+00:00|6.802134|376 passed,5.82 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1103 audited files,977 Haskell paths and95 docs match the retained Linux tree;all full-command
frozen-after checks pass. Dated aggregate digests:

- all977:376c9c5eea4142b911f1faf8d749337c3752271d6ffc0036d0d71ce857f13999
- owned952:c3e14d402592a887b7ef66abaecdf89ebe548a70d0f99c839b4e2468cfb2f9fa
- docs95:03e3413041c9ce8ce5e60804e27cfc11e5bcb3233fb790d9b140140fbda6da00

Only Handoff adopts canonical framing/hashing. All975 other Haskell files and683 compiler fixtures
remain exact;HandoffSpec adopts only two hash-name strings. All five complete named source subjects,
their Aeson bytes and fixed hashes,the raw6323 response bytes,119-line and thirteen-reader controls,
capability/path and Relay4292 subjects,independent vectors and authority/package contracts pass.
The owned ledger row is removed only after actual321-case validation;all other ledger bytes remain
exact. Full baseline reversals pass32/34 production lines,4/4 test lines and3/3 docs lines. No new
type,Cabal edge or module reexport is added. Phase1 inputs/evidence stay current. No base/warm input
changes. Provider-live is not requested/Unsupported;no live-substrate claim is made. The phase's own
declared gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T23:32:21.406928+00:00 to 2026-11-02T23:32:30.003712+00:00,
8.596818 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.70: Activation hashes through Digest [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 400 changed nonempty production lines across at most three modules; one named contract/type or one caller adoption
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Adopt one actual owner's canonical hashing/framing implementation. This is one owner adoption
with unchanged bytes and no new contract/type.

#### Deliverables

- Import canonical sha256Hex and remove only Activation's duplicate; retain Ed25519 convert.
- Keep manifest/secret/signature vectors,checked producers,roles,store/policy and seven axes exact.
- Use the existing dependency; add no new API,Cabal edge or other owner adoption.

#### Validation

BuildAuthoritySpec,HandoffSpec and ActivationSpec retain independent byte/signature controls and
positively named subjects. Remove only this owner's now-gone legacy row after actual validation.
Run all four host-static commands and record actual cases,hosts,results and preservation evidence.
The phase's separate declared gate remains due at phase closure.

Dated2026-11-02 baseline23:32:40.461312 UTC captures63 texts,977 Haskell files and683 fixtures.
Only Activation imports canonical sha256Hex through the existing dependency. Its identical local
definition and four hash-only imports disappear;Ed25519 convert remains. No public API,type,Cabal
edge or other owner changes. Existing checked producers,seven axes,store/policy,role,manifest,
private-bundle and signature subjects remain exact. All specs and compiler fixtures stay unchanged.
The component map records this actual adoption;the Activation ledger row is removed after focused
validation passes below.

Actual native100-argument before controls retain the existing23 observations,four Handoff framing/
hash vectors,five complete positively named source bundles,their Aeson bytes and unchanged expected
hashes,and exact6323 rooted-response bytes. The additional Activation probe computes five actual
opaque secret digests (empty,binary,all256 values,257 FF bytes and the existing private bundle)
against Python SHA-256. Its complete rendered manifest equals twelve independently framed fields,
roundtrips through the actual checked decoder,and retains the existing literal digest
22bfd7a1531c8d361ab705b72ee47fd6f803d2d01837af99f2b4287496dae78c.
Before-state Show outputs and the seed97 actual public-key bytes are captured for exact comparison.
The complete local SHA-256 definition equals canonical Digest bytes.

|Actual before subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|compile-Binding|2026-11-02T23:32:46.831219+00:00 to2026-11-02T23:32:49.047213+00:00|2.216008|0|
|execute-Binding|2026-11-02T23:32:49.047239+00:00 to2026-11-02T23:32:49.112215+00:00|0.064986|0|
|compile-Authority|2026-11-02T23:32:49.112312+00:00 to2026-11-02T23:32:51.325499+00:00|2.213211|0|
|execute-Authority|2026-11-02T23:32:51.325522+00:00 to2026-11-02T23:32:51.436022+00:00|0.110513|0|
|compile-HandoffData|2026-11-02T23:32:51.436117+00:00 to2026-11-02T23:32:53.716785+00:00|2.280693|0|
|execute-HandoffData|2026-11-02T23:32:53.716809+00:00 to2026-11-02T23:32:53.801080+00:00|0.084283|0|
|compile-HandoffBundles|2026-11-02T23:32:53.801183+00:00 to2026-11-02T23:32:58.301221+00:00|4.500078|0|
|execute-HandoffBundles|2026-11-02T23:32:58.301276+00:00 to2026-11-02T23:32:58.636368+00:00|0.335104|0|
|compile-ActivationData|2026-11-02T23:32:58.636520+00:00 to2026-11-02T23:33:03.011920+00:00|4.375436|0|
|execute-ActivationData|2026-11-02T23:33:03.011940+00:00 to2026-11-02T23:33:03.158628+00:00|0.146698|0|

All successful compiles/executes have empty stderr and all63 source/metadata subjects stay frozen.
Actual native builds,after-state controls,focused validation,owned ledger removal and all-four
static results follow. No base/warm inputs change.

Actual native100-argument after controls use source-identical witnesses and unchanged warning
policy,with all63 source/metadata subjects frozen. Five actual Activation digest vectors,the complete
manifest bytes,checked decoder,three Show precedences and seed97 public-key bytes equal the before
state. The independent manifest and private-bundle hashes remain22bfd7a1 andf1bed372 respectively,
with no expected-value rebase. All23 prior data observations,four Handoff framing/hash vectors,
five complete named bundle entries and Aeson bytes/fixed hashes,and raw6323 response bytes remain
exact. Existing ActivationSpec also retains its independent64-byte Ed25519 signature and domain
refusal;actual focused and complete suites pass below.

|Actual after subject|UTC start to end|Seconds|Result|
|---|---|---:|---|
|compile-Binding|2026-11-02T23:34:00.605629+00:00 to2026-11-02T23:34:02.768036+00:00|2.162443|0|
|execute-Binding|2026-11-02T23:34:02.768106+00:00 to2026-11-02T23:34:02.837074+00:00|0.068977|0|
|compile-Authority|2026-11-02T23:34:02.837182+00:00 to2026-11-02T23:34:05.132115+00:00|2.294959|0|
|execute-Authority|2026-11-02T23:34:05.132142+00:00 to2026-11-02T23:34:05.201262+00:00|0.069133|0|
|compile-HandoffData|2026-11-02T23:34:05.201359+00:00 to2026-11-02T23:34:07.325727+00:00|2.124392|0|
|execute-HandoffData|2026-11-02T23:34:07.325752+00:00 to2026-11-02T23:34:07.392626+00:00|0.066886|0|
|compile-HandoffBundles|2026-11-02T23:34:07.392736+00:00 to2026-11-02T23:34:11.910633+00:00|4.517937|0|
|execute-HandoffBundles|2026-11-02T23:34:11.910692+00:00 to2026-11-02T23:34:12.278075+00:00|0.367397|0|
|compile-ActivationData|2026-11-02T23:34:12.278272+00:00 to2026-11-02T23:34:14.601960+00:00|2.323714|0|
|execute-ActivationData|2026-11-02T23:34:14.601987+00:00 to2026-11-02T23:34:14.669871+00:00|0.067894|0|

All successful compiles/executes have empty stderr.
Actual native core Main passes2026-11-02T23:33:29.684202+00:00 to2026-11-02T23:33:47.251134+00:00,
17.567034 seconds,0/empty stderr,frozen source/metadata.
Actual native demo Main passes2026-11-02T23:33:29.694241+00:00 to2026-11-02T23:33:57.646205+00:00,
27.952136 seconds,0/empty stderr,frozen source/metadata.
The complete baseline reversal measures11 nonempty/12 physical production lines in one module,
zero test lines and two component-map lines;the owned ledger row is removed after focused
validation below. Only the declared canonical hash and imports change. Native test builds,focused cases,
owned ledger removal and all-four static results follow.

Actual focused BuildAuthoritySpec/HandoffSpec/ActivationSpec/Doc validation passes321 cases
2026-11-02T23:36:27.979408+00:00 to2026-11-02T23:37:32.333931+00:00,64.24 reported/64.354909 wall seconds,parent0/
empty stderr,frozen source,binary and actual compiler metadata. The three POSIX-only Build cases
retain their exact measured Unsupported rows on Windows;the actual Windows name case runs.
Only after that terminal pass,the single Activation ledger row is removed at2026-11-02T23:37:34.727500+00:00;all other
ledger bytes remain exact. Existing manifest/private-bundle/signature vectors,checked producers,
roles,store/policy and seven axes pass without changing their subjects. Final preservation and
all-four static results follow.

Actual native core test compilation passes2026-11-02T23:34:35.764356+00:00 to2026-11-02T23:36:24.589699+00:00,
108.826016 seconds,0/empty stderr,rts_thr,frozen source/metadata.
Actual native demo test compilation passes2026-11-02T23:34:35.772635+00:00 to2026-11-02T23:34:59.526574+00:00,
23.754089 seconds,0/empty stderr,rts_thr,frozen source/metadata.
Final full baseline source reversals pass11 nonempty/12 physical production lines in Activation,
zero test lines and3/3 owned docs lines. All976 other Haskell files,977 paths,683 compiler fixtures,
all tests and97 export pins stay exact. Every unowned captured text,Cabal edge,canonical Digest,
Ed25519 convert and other ledger byte remains unchanged. Text stays LF;scoped diff checks pass.
These source checks make no runtime claim;the actual321-case pass above and all-four commands below
supply execution evidence.

All167 actual native demo tests pass2026-11-02T23:37:52.158930+00:00 to2026-11-02T23:37:57.309144+00:00,
5.11 reported/5.150228 wall seconds,parent0,frozen source/binary/actual plan.json.
The optional reported build-info file is absent;actual metadata is frozen. Existing teardown-refusal
diagnostics remain;the actual suite and parent pass.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-02T23:38:29.055086+00:00 to2026-11-02T23:46:23.219492+00:00|474.167375|All4012 passed,358.53 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-02T23:38:29.055119+00:00 to2026-11-02T23:46:20.557049+00:00|471.504884|All167 passed,1.62 reported seconds; All4012 passed,358.70 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-02T23:38:29.054301+00:00 to2026-11-02T23:38:30.000515+00:00|0.946197|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-02T23:38:29.054707+00:00 to2026-11-02T23:38:36.402578+00:00|7.347900|376 passed,6.19 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1103 audited files,977 Haskell paths and95 docs match the retained Linux tree;all full-command
frozen-after checks pass. Dated aggregate digests:

- all977:8d9f68e188a925791dfbc8c6abab3179f02b31ae09bb68e97a503fcde91557e6
- owned952:f59a089c82868b6e0d886f900ccd1fc7750ce2d3747202fd0b07e3c5a19cef46
- docs95:10cdbc97a87e791cbb40fe951cbb8686267779750b5374396cf0023d189fcc3a

Only Activation imports canonical hashing. All976 other Haskell files,all tests,97 export pins and683
compiler fixtures remain exact. The actual five opaque digest vectors,complete independently framed
manifest bytes,checked decoder,Show values and public-key bytes match before-state captures;existing
independent Ed25519 signature/domain and checked producer,role/store/policy and seven-axis controls pass.
All binding/Handoff named subjects and bytes stay unchanged. Only the validated Activation ledger row
is removed,after actual321-case validation;all other ledger bytes remain exact. Full baseline reversals
pass11/12 production lines,zero test lines and3/3 docs lines. No new type,Cabal edge or module reexport.
Phase1 inputs/evidence stay current. No base/warm input changes. Provider-live is not requested/
Unsupported;no live-substrate claim is made. The phase's own declared gate remains due.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-02T23:46:30.725237+00:00 to 2026-11-02T23:46:36.924480+00:00,
6.199262 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 13.71: The authenticated sibling config install fails closed [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Install/Native.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Production budget**: at most 400 changed nonempty lines across three modules; one sibling-install completion policy
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

A child frame installs the configuration its parent authenticated beside its own executable through
`installAuthenticatedProductionSiblingConfig` and `installAuthenticatedHarnessSiblingConfig`, which take an
`AuthenticatedConfigPayload` and publish with Phase 7's create-if-absent hard link (`linkNoReplace`). The
install fails closed: it never follows a link at the destination or its lock, and a completed install is
never reported as failed nor leaves its temporary behind.

#### Deliverables

- A symlinked or non-regular destination is `SiblingConfigUnsafeDestination`, and a symlinked lock path is
  `SiblingConfigInstallFailed`; neither touches the link target or directory.
- Once `linkNoReplace` succeeds, the temporary is removed best-effort in a `finally`, so neither a throwing
  post-link inspection nor a failed cleanup leaves a `.hostbootstrap-config.tmp*` file or reports a completed
  install as failed.
- Concurrent installers of one payload converge: exactly one reports `SiblingConfigInstalled` and the other
  `SiblingConfigAlreadyPresent`, and a foreign replacement is `SiblingConfigConflict` with its bytes kept.

#### Validation

`HandoffSpec` "authenticated sibling install is atomic, idempotent, and conflict-preserving" covers the
hard-link install, the concurrent replay, and the conflict. The sprint closes when these cases also exist and
pass under `cabal test all` from `core/`:

- `HandoffSpec`: with the sibling path pre-created as a symlink, and separately as a directory,
  `installAuthenticatedProductionSiblingConfig` returns `Left (SiblingConfigUnsafeDestination path)` and the
  link target or directory is untouched; with `<path>.hostbootstrap-handoff.lock` pre-created as a symlink it
  returns `Left (SiblingConfigInstallFailed path)`. Each symlink case remains compiled and registered; an unavailable creation row asserts its actual
  unsupported observation with conditional completion accounting.
- `HandoffSpec`: `installAuthenticatedHarnessSiblingConfig` installs and then replays as
  `SiblingConfigAlreadyPresent` under a fixture harness payload.
- `HandoffSpec`: `linkNoReplace` onto a taken destination throws and leaves the destination's bytes intact.
- After every sibling-install case, the binary's directory holds no `.hostbootstrap-config.tmp*` file.
- `HandoffSpec` "authenticated sibling install is atomic, idempotent, and conflict-preserving" forks both
  installers blocked on one shared start `MVar ()` that the test fills only after both threads are waiting,
  and repeats that race 50 times (removing the sibling and its lock between rounds), each round asserting
  exactly one `Right SiblingConfigInstalled` and one `Right SiblingConfigAlreadyPresent`. The sibling path is
  one other specs also write; that sharing is safe only because `test/Spec.hs` runs the tree under
  `localOption (NumThreads 1)`, and a comment on the case says so.

Dated2026-11-02 baseline23:46:43.970649 UTC captures65 texts,977 Haskell paths and683 compiler
fixtures. The bounded production owner is Config.Schema;Config.Install.Native remains the actual
no-replace primitive and needs no public exposure or Cabal change. CompileFailSpec owns one
test-only assertion helper:it resolves the existing actual compiler context and narrowly exposes
only Config.Install.Native to one temporary executable. HandoffSpec calls that helper for the real
taken-destination kernel case. All ordinary five-module mixin arguments,private refusals and public
compile-fail subjects remain unchanged.

CoverageManifest owns a two-case sibling-config-symlink family. Both cases stay compiled and
registered on every host;one shared actual creation probe on the running binary's filesystem selects
the row or asserts its precise unavailable observation. Control,inspection and cleanup errors fail
rather than becoming Unsupported. A separate regular-directory case remains unconditional.
The race uses forkFinally result callbacks and observes both actual workers blocked on the shared
start MVar before releasing it;each of50 rounds has exactly one creator and one replay.

Native Windows preflights write only temporary harness files and leave all1103 repository subjects
exact. The actual100-argument private primitive probe plus the explicit one-module selection
compiles23:41:40.612676 to23:41:42.280296 UTC,1.667629 seconds,then runs23:41:42.280313
to23:41:42.461960,.181658 seconds;both0/empty stderr,and the taken destination remainsold.
Actual System.Directory.createFileLink/pathIsSymbolicLink readsTrue and originalnew bytes,
compile23:42:14.808963 to23:42:16.673861,1.864906 seconds;execute23:42:16.673877 to
23:42:16.847352,.173486 seconds,both0/empty stderr. A shared readMVar barrier reports the
actual ThreadBlocked BlockedOnMVar before release,compile23:45:36.068526 to23:45:37.747144,
1.678624 seconds;execute23:45:37.747160 to23:45:37.897828,.150680 seconds,both0/empty stderr.
These preflights validate the test routes only;no sibling-install completion claim is made from them.
Implementation,actual native/focused/all-four checks and the phase's separate gate remain due.

The bounded implementation changes43 nonempty/43 physical production lines in Config.Schema.
Temporary cleanup catches only IOException through catchIOError;asynchronous cancellation remains
uncaught. The complete post-link classification runs under finally removeTemporary. Successful
publication retains its Installed result when its reread is unavailable;readable foreign replacements
retain Conflict/Unsafe classifications. Refused-link race classifications remain unchanged.

Six additional HandoffSpec cases are registered:the two conditional sibling-config symlinks,
the unconditional regular directory,Harness install/replay,native taken destination,and the complete
cleanup/cancellation source clause. The existing race now repeats50 times,observing both actual
workers blocked on the shared readMVar start before release. forkFinally callbacks report worker
exceptions instead of leaving a result wait unresolved. Shared sibling paths remain serialized by
Spec.hs NumThreads1. Every install case checks for absent .hostbootstrap-config.tmp files;fixtures
also remove dangling symlinks by inspecting the link before target existence.
The narrow test-only native assertion retains all ordinary hidden-import subjects and actual mixin
arguments. CoverageManifest declares exactly two symlink cases and row/refusal completions.
Native implementation,package descriptions,SourceGuard and all683 compiler fixtures remain unchanged.
The architecture text states the actual completion and refusal policy. Source delta reversals pass
43/43 production,317/327 tests and8/9 docs lines. These source checks claim no runtime completion.
Native compilation,focused filesystem cases,all-four static commands and the separate phase gate
remain due.

The first native core/demo builds both refuse GHC-58481 at the finalizer's closing parenthesis
(23:52:52 to23:52:53 UTC);neither is passing evidence. A local classifyPublication action preserves
the same complete branches and applies finally without that layout ambiguity. The final production
delta is43 nonempty/43 physical lines in one module;test317/327 and docs8/9 reversals still pass.

Actual native core Main passes2026-11-02T23:53:33.422712+00:00 to2026-11-02T23:53:44.895129+00:00,
11.472483 seconds,0/empty stderr,frozen source/metadata.
Actual native demo Main passes2026-11-02T23:53:33.415005+00:00 to2026-11-02T23:53:46.312323+00:00,
12.897398 seconds,0/empty stderr,frozen source/metadata.
Native test compilation and actual cases remain due;no source-only result closes the sprint.

The initial core test compilation refuses the unused forkIO import under Werror at
23:55:03.126272 to23:55:14.281164 UTC,11.154947 seconds,parent1. Removing that now-unused
import retains the warning policy. The first targeted run selects all7 sibling cases,23:57:28.502109
to23:57:32.449725 UTC,3.947618 wall seconds,parent1:all six runtime cases pass,including both actual
Windows symlinks and50 shared-barrier races;the structural cleanup clause fails because its expected
fragment omits the infix backticks. The full positively named clause assertion now names
classifyPublication followed by infix finally removeTemporary;no frozen protocol expectation changes.

Actual native core test compilation passes2026-11-02T23:58:13.537679+00:00 to2026-11-02T23:59:04.864347+00:00,
51.326992 seconds,0/empty stderr,rts_thr,frozen source/metadata.
Actual native demo test compilation passes2026-11-02T23:55:03.193539+00:00 to2026-11-02T23:55:09.523682+00:00,
6.330187 seconds,0/empty stderr,rts_thr,frozen source/metadata.
Actual native targeted sibling selection passes all7 cases,2026-11-02T23:59:29.374415+00:00 to2026-11-02T23:59:32.100597+00:00,
2.62 reported/2.726170 wall seconds,parent0/empty stderr,frozen source,binary and compiler metadata.
Actual native BuildAuthority/Handoff/Activation/Schema/Doc selection passes all387 cases,2026-11-02T23:59:36.542188+00:00 to2026-11-03T00:00:48.694584+00:00,
72.03 reported/72.152830 wall seconds,parent0/empty stderr,frozen source,binary and compiler metadata.
The actual native catalogue has4019 cases. A retained Linux prior-tree catalogue has4012 and
its1103 audited files match the prior snapshot;this is an actual prior built-tree comparison,not a
native-before-state claim. Every prior non-manifest label remains;the only six new non-manifest cases
are the named Handoff additions. The seventh additional case checks the new two-case conditional
family declaration. Manifest availability names remain host-specific. All labels,binary and actual
compiler metadata stay frozen during native enumeration. Both symlink cases execute their real
Windows row without Unsupported;the three existing POSIX-only Build cases retain exact refusal rows.

Complete source reversals preserve all973 other Haskell files,all977 paths and683 compiler fixtures.
All preexisting compiler cases/resolvers and ordinary test mixin arguments remain exact;the additional
native one-module selection belongs only to its explicit temporary runtime probe. All preexisting
Handoff tests and frozen subjects outside the owned sibling case/fixture cleanup remain exact.
Native,SourceGuard,97 export pins,Cabal,all unowned captured text and other conditional-family bytes
stay unchanged. Only the declared architecture paragraph is added. Text is LF;scoped diff checks pass.
The final delta is43/43 production,317/327 tests and8/9 docs lines. No base/warm input changes occur.
Actual all-four static commands and the phase's separate gate remain due.

All167 actual native demo tests pass2026-11-03T00:01:13.571792+00:00 to2026-11-03T00:01:18.735698+00:00,
5.13 reported/5.163918 wall seconds,parent0,frozen source/binary/actual plan.json.
The optional reported build-info file is absent;actual metadata is frozen. Existing teardown-refusal
diagnostics remain;the actual suite and parent pass.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-03T00:01:28.122619+00:00 to2026-11-03T00:08:44.169178+00:00|436.049281|All4019 passed,374.99 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-03T00:01:28.122863+00:00 to2026-11-03T00:08:43.351833+00:00|435.231687|All167 passed,2.21 reported seconds; All4019 passed,377.78 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-03T00:01:28.159778+00:00 to2026-11-03T00:01:29.238269+00:00|1.078479|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-03T00:01:28.196128+00:00 to2026-11-03T00:01:37.114730+00:00|8.918628|376 passed,7.51 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
Actual conditional completion evidence for the two registered sibling-symlink cases:

- core:actual completed row/refusal callbacks(2,0);the family count and branch-comparison cases pass.
- demo:actual completed row/refusal callbacks(2,0);the family count and branch-comparison cases pass.

All1103 audited files,977 Haskell paths and95 docs match the retained Linux tree;all full-command
frozen-after checks pass. Dated aggregate digests:

- all977:b4f53717d266cdacc29a4fa4eed7b1ed4653e6752997de6e0a1329a92ae29b33
- owned952:5a1d5a20db9ff6213ce128b978d47d510781719b929b94e0d94fea3c5b1b0097
- docs95:fcba0eab24cbce644e1baeb5530486eb4f2596c4a3b1755ce236f30705f6b769

Final source preservation holds all973 unrelated Haskell files,all683 compiler fixtures,all prior
compiler cases/resolvers and ordinary mixin arguments,Native,SourceGuard and97 export pins exact.
All preexisting Handoff frozen subjects remain unchanged outside the declared sibling case/fixture
cleanup;only the two-case conditional family is added. Full baseline reversals pass43/43 production,
317/327 tests and8/9 docs lines. No new production type,Cabal edge or module exposure. All actual
filesystem cases keep destinations intact and leave no config temporary. Phase1 inputs/evidence stay
current;no base/warm inputs change. Provider-live is not requested/Unsupported. These completed
all-four commands do not substitute for the phase's separate declared focused plus -j1 gate.

Actual separate phase13 closure gate,after all four final sprint commands:

|Declared phase-gate leg,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end|Wall seconds|Actual result|
|---|---|---:|---|
|complete Handoff/public compile-fail/ProjectPlan/Doc focused selection|2026-11-03T00:08:59.309982+00:00 to2026-11-03T00:11:54.366405+00:00|175.057505|All1154 passed,169.79 reported seconds;Cabal PASS,parent0;frozen-after exact|
|core/:cabal test all -j1|2026-11-03T00:12:05.156684+00:00 to2026-11-03T00:16:52.010153+00:00|286.855221|All4019 passed,281.68 reported seconds;Cabal PASS,parent0;frozen-after exact|

The focused catalogue proves all four declared groups are selected completely,including every public
compile-fail boundary subject and the full indexed project-plan foundation. Both commands carry -j1;
the full leg has no pattern filter. The actual source/owned-doc snapshot remains fixed throughout
both terminal runs. Phase13 closes on these own declared legs,with all71 sprints Done and no owed
work in its scope. All final filesystem,preservation,private-boundary and conditional-completion
claims retain their actual subjects and hosts above.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T00:17:03.505442+00:00 to 2026-11-03T00:17:09.486894+00:00,
5.981472 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the surface this phase changes in it.
- `documents/architecture/build_and_run_model.md` — the surface this phase changes in it.

- `documents/architecture/binary_context_config.md` — challenge/grant admission, authenticated scope,
  recovery package, and private duplex transport.
- `documents/architecture/lifecycle_state_model.md` — root-owned coordination, storeless child exchange,
  signed responses, and receipt order.
- `documents/architecture/unrepresentable_state.md` — hidden constructors, rank-2 scope admission, closed
  rooted vocabulary, and keyless relay boundaries.
- `documents/architecture/harness_workflow.md` — the Harness producer of exact run evidence for the generic
  authenticated-scope capsule.

**Engineering docs to create/update:**

- `documents/engineering/build_release.md` — reusable Build authority and its concrete consumer boundary.
- `documents/engineering/config_generation.md` — exact config projection inside config and recovery payloads.
- `documents/engineering/secrets.md` — independently installed project/Build/Activation verification keys
  and the keyless child/intermediary rule.

**Cross-references to add:**
- `documents/README.md` — the surface this phase changes in it.

- `development_plan_standards.md` §§ X, Y, EE, and HH name this phase as the owner of authenticated handoff,
  root scope, rooted wire/receipt vocabulary, and keyless relay transport.
- Phase 17 (the recursive lifecycle command) consumes these contracts for root-owned durable coordination and
  storeless frame execution.
- Phase 19 (test harness and run ownership) supplies the exact Harness run evidence consumed by the generic
  authenticated-scope producer.
- Phase 24 (the worked demo) consumes Build authority and confirms the recursive lifecycle on its live
  provider chain.
