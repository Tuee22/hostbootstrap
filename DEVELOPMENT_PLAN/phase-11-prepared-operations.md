# Phase 11 — Prepared operations and preconditions

**Status**: Active
**Depends on**: Phase 10 (versioned sessions, the project journal, and durable fences)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: Make every external effect require a value whose only lawful origin is one protected
> compare-and-swap taken immediately before it, over freshly re-probed evidence.

## Phase Objective

This is the gate every reservation, mutation, and delete passes through. An adapter does not accept a request;
it accepts a `PreparedOperation` paired with the `PreparedPreconditions` minted with it, and the pair records
the exact target identity, generation, operation key, precondition set, call digest, session, fence, attempt,
and journal version. Anything stale, replaced, or not-ready yields no pair at all.

The point is not extra checking. It is that a caller has no way to *express* an effect without the pair, so
"the preconditions were verified before the call" is a fact about the type rather than a discipline.

## Sprints

### Sprint 11.1: Prepared gate coordinate opacity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgePreparedGate.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdatePreparedGatePlan.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdatePreparedGateOperation.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdatePreparedGateSession.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdatePreparedGateFence.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdatePreparedGateAttempt.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdatePreparedGateJournalVersion.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Seal the six retained PreparedGate coordinates against record update while preserving ordinary
inspection, Show and canonical bytes. This is held-value opacity, not closure of every producer:
`withPreparedGate` is the checked local production path; the still-public low-level
`recordDurableUnknown` accepts caller coordinates. The routed mint in Lifecycle.FrameExecutor and
removal of that public writer remain owned by Sprint 17.72. Field transport and canonical test
addresses are separate contracts in Sprints 11.2 and 11.3.

The production same-origin law remains: the local mint publishes the unknown phase through the
protected transaction at the canonical plan/session/operation address, re-reads that committed row,
and only then admits the adapter with its recorded version. A routed reifier requires an
authenticated exact response proving that same root publication and all coordinates; a transport
receipt or caller assertion alone is not a minting proof.

#### Deliverables

- PreparedGate's constructor and mint remain package-private. All six public coordinate names are
  ordinary functions over a representation with no public record labels.
- Preserve the reader types and values, Eq, the existing record-shaped Show including precedence,
  preparedGateFields, commitment bytes and every production mint call.
- Correct the Prepared header and writer Haddock: name Session.withPreparedGate as the checked local
  path and describe its journal checks; the low-level writer receives caller-selected coordinates
  and only its returned journal version comes from the committed store write.
- Each of the six existing typed record-update fixtures names its actual imported reader and a
  correctly typed replacement. Measure public compilation before sealing and require the actual
  unavailable-record-field diagnostic afterwards; preserve the genuine constructor child-import proof.
- Retain local durable-before-callback, stale/consumed permit, plan/operation and phase refusal controls.
  Pin successful reader values, record-shaped Show and canonical field/commitment compatibility.
- Align the two architecture docs and remove only the resolved public-selector ledger row after the
  actual representation change. Keep the low-level producer and later-owner limitations explicit.

#### Validation

SessionSpec retains "a prepare records the unknown phase before the adapter runs", "the consumed
journal version cannot acknowledge twice", "a settled operation cannot be prepared again", "a terminal
operation receives no effect authority", "a prepare against a superseded fence is refused", "an
unregistered operation cannot prepare", "a stale project permit cannot drive a prepare" and "a
terminally closed project refuses every prepare". ReconcileSpec retains "a gate recorded for another
operation cannot prepare this one" and "a gate recorded in another plan's journal cannot prepare".
ProjectPlanSpec retains its mint-site allowlist for Session, FrameExecutor and the two Prepared modules.

The six RecordUpdatePreparedGate fixtures use typed replacements, so an unrelated String/Text
mismatch cannot satisfy a negative. Their unchanged public-only compiler controls must succeed before
sealing and fail afterwards for the observed reader-field diagnostics. ForgePreparedGate imports the
real constructor child rather than importing only the abstract type. Successful gate controls must
retain every reader, Show precedence and canonical field/commitment byte result.

Run those focused compiler/runtime controls, sealed inventory and DocValidatorSpec on both hosts,
then the unfiltered core gate and all four host-static commands of section JJ. Record actual results
before closure; this sprint introduces no codec, fixture-address or producer-admission behavior.

2026-10-29: Native Windows x86_64 and the native Linux x86_64 gate container, both GHC 9.12.4 /
Cabal 3.16.1.0, passed `cabal build all` from `core/` under the package's warning policy. With the same
public-main-only compiler arguments, all six typed update fixtures compiled before sealing and each
failed afterwards with GHC-22385 naming its actual missing record field. The genuine constructor-child
import failed with GHC-10237 on both sides of the change; its measured diagnostic is registered without
claiming a newly closed constructor gap. The preceding successful store-backed callback passed on both
hosts, including the Show precedence and nested-value expectations.

The focused Cabal runs then passed, respectively on Windows / Linux: six registered updates
(1.59 / 0.91 seconds), the constructor boundary (0.47 / 0.16), the successful durable callback
(0.31 / 0.32), all 282 SessionSpec cases (47.21 / 51.97), the exact mint-site guard (1.57 / 1.53),
all 19 sealed-export inventory cases (0.25 / 0.19), and all 17 DocValidatorSpec cases (8.28 / 5.70).
Every parent command exited zero with no failing test context. The production change is 86 changed
lines across two modules; field projection, commitment, codec, writer and mint bodies are unchanged.
The provider-live opt-in lane was not requested; these results claim static coverage only.

The complete four-command host static gate also passed on 2026-10-29. Each host ran
`cabal test all` from `core/`, `cabal test all` from `demo/`, then
`poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root. Native Windows passed
3,539 core cases in 537.89 seconds; its demo leg passed 165 cases in 5.74 seconds and the included
3,539 core cases in 507.48 seconds. Python code checks passed and all 376 Python cases passed in
6.46 seconds. Linux passed 3,541 core cases in 425.68 seconds; its demo leg passed 165 cases in
1.96 seconds and the included 3,541 core cases in 419.08 seconds. Python code checks passed and
all 376 Python cases passed in 7.05 seconds. Every command in these complete runs exited zero,
with no failing test contexts; source and test bytes remained frozen throughout.

The first Windows unfiltered core attempt is retained as a failed run: one of 3,539 cases failed
in 562.77 seconds. In CLISpec's "Destroy resumes the retained Pending continuation after Down",
the first project Up returned ExitFailure 1 at line 1582, before Down or Pending construction.
Captured stderr also reports a protected-record MoveFileEx publication refused with "Access is
denied". That error can propagate to the observed CLI exit, but the aggregate diagnostic does
not establish the process or condition that denied access. The unchanged isolated case passed
(1 case, 1.62 seconds), and the unchanged complete Windows four-command rerun passed as recorded
above; its core run includes that case passing in 1.50 seconds. No production retry or unrelated
source change is inferred from the non-reproduction. No live provider or hardware acceptance
completion is claimed.

#### Remaining Work

None.

### Sprint 11.2: Exact UTF-8 prepared-record fields [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make the shared prepared/session field transport preserve exact UTF-8 rather than truncating Text
through Char8. The round-trip domain is a nonempty list of delimiter-free fields; encodeFields has
no refusal channel, and the empty bytes cannot distinguish an empty list from one empty field.
The existing seven-name unknown-phase whitelist already rejects arbitrary phase text; that policy
is not evidence that field encoding preserves Unicode. The unchecked low-level writer and its
removal remain with Sprint 17.72; no generic separator-validation or new runtime admission is claimed.

#### Deliverables

- Replace Char8 field conversion with TextEncoding.encodeUtf8 and strict decodeUtf8', preserving
  existing tab-delimited record shapes, valid ASCII bytes and exact field spelling without trimming.
- Strict decoding returns the existing empty-list failure sentinel for invalid UTF-8 rather than
  inventing replacement characters. Preserve existing signatures and valid ASCII record bytes;
  do not claim a generic separator refusal or a round trip outside the declared field domain.
- Use independent pure field-byte and round-trip controls, including a character above U+00FF and
  invalid UTF-8 input, to expose the actual codec defect before the change and hold exact transport.
- Add separate SessionSpec controls for tab, newline and above-U+00FF unknown-phase requests:
  require the existing exact typed refusal, no callback and unchanged record version/image. The
  seven-phase policy already implements these refusals; the new regressions must pass before the
  codec change. Retain the existing terminal and unrecognised-phase request controls separately.
- Correct the Prepared record-encoding comment and lifecycle description while preserving numeric,
  journal, fence, phase-category and transaction-codec policies already completed in Phase 10.

#### Validation

Measure the independent encode/decode controls against the actual preceding Char8 codec, with a
literal expected UTF-8 byte sequence rather than a production-derived expectation. Valid Unicode
field round trips and invalid UTF-8 refusal must exercise the codec directly. SessionSpec's prepare
request controls must keep their genuine registered operation, current permit and unchanged post-setup
record/image; a whitelist refusal alone is not a codec RED. Run focused codec/admission controls,
SessionSpec, inventory and DocValidatorSpec, then the complete declared core and host-static gates.

2026-10-29: Native Windows x86_64 and the native Linux x86_64 gate container (GHC 9.12.4 /
Cabal 3.16.1.0) measured the new controls against the unchanged Char8 implementation. The five
"prepare refuses requested phase" cases passed (0.80 / 1.13 seconds, Windows / Linux), including
the new tab, newline and U+0100 requests: exact typed refusals, zero callbacks, unchanged operation
bytes and physical versions, and unchanged post-setup protected images. These are existing-policy
controls, not codec failures.

The separate "prepared record field codec" group produced three semantic failures out of four
(0.03 / 0.04 seconds). U+0100 encoded as NUL instead of the literal UTF-8 C4 80 bytes; the independent
C4 80 input decoded as two incorrect characters; the malformed-input control returned text for FF
instead of the failure sentinel. The ASCII/whitespace/empty-field control passed. Both expected
failing parent commands exited one; no build or unrelated setup error supplies this RED evidence.

The first post-change focused runs passed all four codec controls on each host (0.03 seconds),
and all five requested-phase refusals (0.78 / 1.11 seconds, Windows / Linux). Linux also passed
all 289 SessionSpec cases (58.01 seconds), all 19 sealed-export cases (0.18), and all 17 documentation
cases (5.07). Windows's complete SessionSpec run instead failed one of 289 cases in 53.63 seconds:
"recovery preserves a maximum attempt without incrementing it" returned SessionStoreFailure with
a protected-record MoveFileEx "Access is denied" publication error. That first failed run remains
recorded; no codec or admission failure is substituted for this I/O observation. Its underlying
Windows denial cause is not established.

With source and test bytes unchanged, the complete focused Windows set was rerun and passed:
four codec cases (0.03 seconds), all five requested-phase refusals (0.77), all 289 SessionSpec
cases (41.06), all 19 sealed-export cases (0.25), and all 17 DocValidatorSpec cases (6.60).
Every command in that complete rerun exited zero with no failing test context. The malformed-input
control now reaches and refuses all three invalid-byte samples; the exact Unicode and ASCII field
controls pass on both hosts. This records non-reproduction of the earlier Windows I/O failure,
not an inferred fix for its underlying cause. The production change is 21 changed lines in one
module; public signatures/exports, gate projection/commitment, mint and writer bodies are unchanged.

The complete four-command host static gate passed on 2026-10-29. Each host ran
`cabal test all` from `core/`, `cabal test all` from `demo/`, then
`poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root. Native Windows passed
3,546 core cases in 559.22 seconds; the demo leg passed 165 cases in 5.78 seconds and the included
3,546 core cases in 528.99 seconds. Python code checks passed and all 376 Python cases passed in
6.43 seconds. Linux passed 3,548 core cases in 430.92 seconds; the demo leg passed 165 cases in
2.14 seconds and the included 3,548 core cases in 409.80 seconds. Python code checks passed and
all 376 Python cases passed in 6.87 seconds. Every command in these complete runs exited zero
with no failing test contexts, and source/test bytes remained frozen throughout. The earlier
focused Windows I/O failure remains recorded above; these passes do not establish its underlying
cause or assert that it is fixed. No live provider or hardware acceptance completion is claimed.

#### Remaining Work

None.

### Sprint 11.3: Canonical prepared-fixture addresses [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/PrepareFixture.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`, `core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Make the adapter fixture's durable address agree with production without exposing the private
operationKeyFor helper. The fixture uses public mkRecordName, the shared Digest SHA-256 over the raw
plan's UTF-8 bytes, and the exact session/operation tuple separator. Only the journal version is
store-derived; callers still select the retained plan, operation, session, fence and attempt.
This is fixture fidelity, not a new gate producer or cleanup-backend policy. The single existing
ColimaSpec consumer adopts the shared fixture's same-session successor; the cluster-lifecycle phase
retains ownership of its cleanup/backend contract. The fixture proof requires only its protected-store
primitives and does not require a provider or a live cleanup run.

#### Deliverables

- Replace operation-plus-sanitize addresses with the exact plan digest, encoded session and encoded
  complete operation tuple; remove sanitize and retain an independent exact-key oracle.
- Correct withGateFor/gateForValues documentation to distinguish caller coordinates from the fresh
  store's first-write version and gateFor's fixed session-1, fence 1 and attempt 1.
- Make withSuccessorGate retain one session and one canonical key, with a genuine checked physical
  version 1-to-2 compare-and-swap. Adapt its sole ColimaSpec caller without changing cleanup behavior.
- Cover namespaced/dotted/path spelling and distinct coordinates through the actual fixture,
  preserving the existing adapter refusal/readback controls and removing only its resolved ledger row.

#### Validation

Compare actual fixture record keys with an independent SHA-256/framing/identity oracle, not the helper
under test. Exercise the successor action against the same canonical record and require its real
physical version increase; a different session's fresh key is not a successor. Run the affected
SessionSpec/ColimaSpec and adapter regressions, inventory and DocValidatorSpec, then the complete core
and host-static gates. No test-only public operation-key producer or cleanup authority is introduced.

2026-10-29: Native Windows x86_64 and the native Linux x86_64 gate container, both GHC 9.12.4 /
Cabal 3.16.1.0, ran the two new "prepared fixture addresses" cases against the retained lossy key
function after the store-observation scaffold and same-session successor API were available. Both
cases failed for actual sole-record key mismatches (0.07 / 0.11 seconds, Windows / Linux): the fixture
wrote operation-only sanitized addresses rather than the independent raw-plan SHA-256, encoded
session and complete encoded-operation tuple. The first lowercase row reached a real write and
key comparison; neither a missing helper nor a malformed setup supplies this RED evidence. The
successor case also refused the wrong stored key before its version assertions, so this result
alone does not establish the physical successor behavior.

After the canonical private key function was applied, the unchanged new cases passed on both
hosts (2 cases, 0.14 / 0.19 seconds, Windows / Linux). All five address rows reached their actual
record/payload/version and six-coordinate checks, including independent raw-plan hashing, complete
path/dotted/case/underscore identity spelling and distinct keys. The successor case reached both
real CAS observations: one session/key/fence, attempts 4 to 5, and physical versions 1 to 2. No
production module, public production API, package dependency or cleanup-backend policy changed.

The complete affected focused sets also passed, respectively on Windows / Linux: SessionSpec
291 cases (53.80 / 58.72 seconds), ColimaSpec 18 (0.26 / 1.22), BudgetSpec 39 (4.46 / 5.63),
ClusterWorkloadSpec 10 (19.25 / 3.90), ProviderBackendSpec 41 (20.63 / 7.22), ReadinessSpec 34
(2.05 / 2.35), and the three ReconcileSpec/ClusterReconcileSpec/ProviderReconcileSpec groups
106 combined (14.82 / 11.58). All 19 sealed-export cases (0.25 / 0.17) and all 17 documentation
cases (6.78 / 6.11) passed. Every focused parent command exited zero with no failing test context;
no opt-in direct-Colima live confirmation is claimed by these static checks.

The complete four-command host static gate passed on 2026-10-29. Each host ran
`cabal test all` from `core/`, `cabal test all` from `demo/`, then
`poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root. Native Windows passed
3,548 core cases in 558.94 seconds; its demo leg passed 165 cases in 5.78 seconds and the included
3,548 core cases in 529.33 seconds. Python code checks passed and all 376 Python cases passed in
6.42 seconds. Linux passed 3,550 core cases in 426.96 seconds; its demo leg passed 165 cases in
1.98 seconds and the included 3,550 core cases in 418.02 seconds. Python code checks passed and
all 376 Python cases passed in 6.88 seconds. Every command exited zero with no failing test
contexts. Test, production and package-description bytes remained frozen throughout; production
modules and package dependencies are unchanged by this fixture-only contract. No live Colima
cleanup or hardware acceptance completion is claimed.

#### Remaining Work

None.

### Sprint 11.4: Zero-dependency prepared pairs [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/engineering/testing.md`

#### Objective

A descriptor with no plan dependencies reaches a pure prepared pair without a caller-retained
precondition set. Existing zero-edge checks and pure start/phase/provision wrappers are partially
built; their single admitted boundary completes that contract. The existing Provider and Colima
consumers adopt this shared boundary as whole-tree compatibility maintenance. Their backend and live
hardware contracts remain owned by their provider and cluster-lifecycle phases; this foundation uses
only the plan, gate and receipt vocabulary already available. Command mode, lease, revision, verb and
frame revalidation belong to the step-algebra phase, not this pair constructor. The generic
dependency-aware phase factory retains its capability; Sprint 11.7 gives that family fresh snapshot
admission after the current zero-edge callers use their explicit pure boundary.

#### Deliverables

- `withPreparedZeroDependencyOperation` and `withPreparedZeroDependencyPhaseTransition` are the
  explicit pure zero-edge family. They accept descriptor/gate continuations without a pre-sealed
  caller value and require an empty descriptor edge set; the phase entry retains receipt and
  transition checks.
- One private checked-set matcher retains the descriptor plan/operation/call-digest binding, exact
  ordered observations, positive attempt/version and gate plan/operation checks. The zero-edge entry
  reaches it only with the internally established empty set and returns no pair on refusal.
- Shared private matching helpers hold the operation and phase policies once. Provider start/
  provision wrappers adopt the zero-operation entry; Provider phase and Colima cleanup consumers
  adopt the explicit zero-phase entry without an IO-signature or backend-policy change. The generic
  dependency-aware withPreparedPhaseTransition capability is preserved.
- `withPreparedGate` retains broker generation, open project/current permit, live Open session,
  registration, fence and phase checks in one protected transaction. Preparation re-reads the live
  session without versioning OperationSession; a consumed permit cannot prepare or close again.
- The adapter still accepts PreparedOperation and PreparedPreconditions together. The journal step
  returns the sole successor ProjectPermit, and terminal observations return a typed failure or
  OperationAdvance whose eliminator retains its result with that sole successor. Retained readiness
  or either prepared half alone supplies no effect authority.
- Reconcile's prepare Haddock names the checked local Session.withPreparedGate path and its checks;
  only the committed journal version comes from the store. Correct DependencySnapshot's producer
  description to cover the actual completion, adoption, phase-advance, planned-rebinding and carrier
  openers rather than an incomplete list.
- Keep the already documented durable-before-adapter control and prepared-pair compiler boundaries
  in testing.md; align the lifecycle description and exact export inventory with the pure zero-edge
  contract. This stage budgets at most 400 changed production lines across the three listed modules.

#### Validation

Retain ReconcileSpec's "the zero-dependency branch refuses an operation that declares edges", adapted
to reach the pure pair entry itself. A genuinely edge-bearing descriptor receives the exact empty-edge
refusal and no callback; a valid zero-edge descriptor/gate yields matching pair coordinates. Exercise
wrong plan/operation and a zero caller-selected attempt, managed receipt/phase binding and existing
Provider/Colima refusal controls without a caller-supplied set. Retain positive journal-version
checks with actual CAS-issued versions and the constructor/record-update boundaries: the public gate
surface cannot mint a zero physical version. The zero-phase entry refuses an edge-bearing
descriptor directly, while generic dependency-aware phase preparation retains its existing capability.

SessionSpec retains all Sprint 11.1 journal revalidation cases, plus "a fenced-retryable phase needs a
fence above the one it was observed at" and "an operation at an unrecognised phase blocks rather than
proceeding". Keep the consumed-version and terminal OperationAdvance controls and the existing
ForgePreparedGate and MismatchPreparedPairRoles compiler boundaries. These assertions preserve the
journal prerequisite independently of the pure pair constructor.

Run focused ReconcileSpec/ProviderReconcileSpec/ColimaSpec, SessionSpec, sealed inventory and
DocValidatorSpec, then all four host-static commands of section JJ on both hosts. Record actual source
size and results before closing this one-contract stage; no live provider is required.

Dated evidence, 2026-10-29, native Windows 11 x86_64, GHC 9.12.4 and Cabal 3.16.1.0:

- The implementation changes 155 production lines across the three declared source modules. The
  explicit pure zero-operation and zero-phase entries, consumer adoptions, private matchers, owned
  Haddocks, governed docs and two exact public-export pins are implemented.
- From `core/`, `cabal test all --test-options='-p "explicit zero-dependency preparation"'` passed
  all 7 controls (0.56 s). The `ReconcileSpec` selection passed 112 tests (15.42 s), including
  ReconcileSpec, ClusterReconcileSpec and ProviderReconcileSpec. `ColimaSpec` passed 18 (0.26 s),
  `SessionSpec` passed 291 (41.97 s), and the `sealed` selection passed 60 (35.80 s), including all
  19 exact sealed-export inventory controls. Each command exited 0; compilation retained `-Werror`.
- The first `DocValidatorSpec` run failed 1 of 17 checks (8.06 s): the dependent-phase test's local
  expression `phase 11` matched the numeric-citation rule. Its local binder is `preparedPhase`;
  no production or validator policy changed. On that tree the unchanged 7 zero-preparation controls
  passed again (0.53 s), `DocValidatorSpec` passed 17 (7.04 s), and `ForgePreparedGate` and
  `MismatchPreparedPairRoles` passed one compiler-boundary test each (0.49 s and 0.57 s).
- The live-provider executable reported its default not-requested branch; these results claim no
  live-provider validation. Linux source sync and test launch returned that the owned gate container
  was not running; no Linux test process started and no Linux pass is recorded.
- The four-command host static gate has not run against this sprint's tree on either host. These
  focused results leave the sprint Active and do not close the phase.

#### Remaining Work

Run the focused ReconcileSpec/ProviderReconcileSpec/ColimaSpec, SessionSpec, sealed inventory,
DocValidatorSpec and prepared-gate/pair compiler controls on Linux. Run all four host-static commands
of section JJ on Windows and Linux against the completed implementation, record their actual results,
and then close this sprint. The pure zero-edge implementation and its documentation are complete.

### Sprint 11.5: The plan-minted execution descriptor [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Give a step a value that names its own node, so it can reach a gate. The descriptor and
Protected token-boundary checks are already implemented; current closure owes exact regression
evidence rather than another parser rewrite.

#### Deliverables

- `StepExecution scope planId` is minted only by the plan and carries the plan digest, the step's own operation
  key and frame, and its exact ordered edge set.
- It has no public constructor, so it exists only inside a real interpretation of a real validated plan.
- The `scope` and `planId` indices are universally quantified at the action, so an action sees them as skolems
  it cannot choose — which is what makes the pairing with a gate's index-carrying values a type-check rather
  than a convention.
- An action derives its node from the descriptor rather than reconstructing it, so the plan and the effect
  cannot disagree about which node ran.
- `withStepPreparedGate` is the local descriptor route to the prepare compare-and-swap: it reads the plan
  digest and the operation key **off the descriptor**, so a step reaches exactly one gate — its own — and
  cannot name a sibling node's operation. It refuses a descriptor whose plan digest is not the session's,
  because those indices are phantom on the session side and would otherwise unify. A hidden routed reifier
  remains subject to Sprint 11.1's same-origin law and must exact-match the authenticated response to the
  descriptor rather than accepting caller-selected coordinates.
- `mkRecordName` is the one injective encoding by which a *namespaced* identity reaches the store's key
  alphabet. Both identities the gate needs are namespaced — a plan operation key (`core:deploy-kind`) and a
  plan digest (`<specDigest>:<planBytesDigest>`) — and a character-replacing sanitizer would let two of them
  share a key. A plain segment carries no `.`, a namespace carries no `.`, and a token neither begins nor ends
  with `.` nor contains `..`, so `..` occurs in an image only as the path separator, `recordNameIdentity`
  inverts every image, and two distinct identities can never share one durable phase record.

#### Validation

`ChainSpec` covers the descriptor's contents and the absence of a public constructor. `SessionSpec` covers
the route: "a step reaches the prepared gate for its own operation" and the encoded record it lands on, "a
descriptor from another plan cannot prepare in this session", and "a plain operation key cannot occupy an
encoded key's record", which refuses `core.deploy-kind` and `a:b:c`.
`cabal test all --ghc-options=-Werror` from `core/` passed 944/944 on 2026-08-05 (aarch64-osx, GHC 9.12.4).

The sprint closes when a `SessionSpec` case exists and passes under `cabal test all` from `core/` asserting
that `mkRecordName` refuses `core:.x` and `core:x.` with `ProtectedInvalid`, and that
`registerOperationIntent` of `core:.x` in a session that holds `core/x` refuses rather than addressing
`core/x`'s record.

#### Remaining Work

- The existing recordNameSegment implementation already refuses a namespaced token beginning or
  ending with a dot. Add the exact SessionSpec regressions declared in Validation: core:.x and
  core:x. yield ProtectedInvalid, and registering core:.x cannot address an existing core/x record.
  Preserve the existing descriptor, cross-plan and plain-versus-encoded route controls and record
  their complete declared gate results; no production parser change is owed.

### Sprint 11.6: Fresh snapshot admission [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/engineering/testing.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Fresh IO preparation validates a gate and descriptor before it observes the complete dependency
snapshot. The chart and existing provider-share path adopt that behavior. The plan-derived edge set
and traversal exist, but this gate-first boundary and these fresh-call adoptions are not started.
The cluster-lifecycle phase owns whether each supplied backend probe performs a real external
re-observation; this foundation owns when it runs and which complete members it must observe.

#### Deliverables

- The fresh snapshot boundary accepts a descriptor, DependencySnapshot, gate and pair continuation.
  Gate/descriptor plan and operation checks and positive attempt/version checks precede all probe IO.
- The prepare owns the complete ordered traversal and its sealed set. It runs every member probe
  itself after the journal gate, refuses missing or duplicate members and stale/replaced/not-ready
  observations, and returns no pair on failure. The empty-edge descriptor takes only the empty branch.
- The descriptor's dependency keys remain the exact ordered resource-bearing prefix derived from
  plan traversal, never a caller-selected subset. The private matcher binds the resulting set to
  that descriptor's plan, operation and call digest.
- Chart preparation and the existing provider-share consumer pass their snapshots into this fresh
  boundary. Each actual member probe runs once during preparation, with no earlier seal retained by
  either caller and no duplicate probe from combining both paths.
- Put the plan-owned traversal Haddock directly on its real traversal signature and describe the
  exact fresh-observation boundary in lifecycle/testing docs. Keep pair/advance and journal laws
  from Sprint 11.4; this stage budgets 400 changed production lines across two modules.
- Record an implementation bridge in the standing-shape ledger only while that code actually
  exists, with deletion owned by Sprint 11.8. The final narrative describes fresh admission behavior,
  and final export/definition inventory admits no duplicate fresh entry.

#### Validation

A counted ready dependency probe reports zero runs before fresh preparation and one afterwards;
assert the actual matching pair. A first-run not-ready probe returns Left with no pair. Wrong gate
plan/operation and invalid attempt/version must return their exact refusals with probe count zero.
The traversal's missing-member and duplicate-member controls exercise the actual preparation path;
retain "chart preparation refuses a failed readiness reprobe", "chart preparation seals exactly its
ready cluster dependency", and "the traversal seals the resource-bearing edge set it derived".

Run focused counted readiness/traversal, chart and ProviderReconcileSpec controls, SessionSpec,
sealed inventory and DocValidatorSpec, then the unfiltered core gate and all four host-static
commands on both hosts. These controls prove observation timing and complete membership, not a
live backend's implementation or an independent journal transaction.

#### Remaining Work

Implement gate-first fresh snapshot admission and chart/provider-share adoption, add counted ready,
first-run not-ready and pre-probe refusal controls, correct traversal documentation and any actual
standing bridge ledger entry, and record all four host-static commands on both hosts.

### Sprint 11.7: Canonical snapshot preparation [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgePreconditionSet.hs`,
`core/hostbootstrap-core/test/compile-fail/MismatchPreparedPairRoles.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`, `documents/engineering/testing.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

The canonical withPreparedOperation boundary takes a snapshot and performs fresh IO preparation;
its Cluster and guest-alias consumers use that boundary. No caller can retain an authoritative
OperationPreconditionSet and present it later. This API/caller adoption is not started. Existing
Cluster and Alias consumers remain compatibility adoptions here; their backend and provider behavior
belongs to their owning phases, independently of this lower prepared-pair contract.

#### Deliverables

- `withPreparedOperation` accepts DependencySnapshot in place of a retained set and returns its
  result in IO. It performs gate/descriptor checks before running the owned complete traversal and
  yields the matching prepared pair only after all required observations pass.
- The generic `withPreparedPhaseTransition` also accepts a snapshot and runs in IO, preserving
  dependency-aware phase preparation. Its receipt/transition checks precede canonical operation
  preparation, and shared private phase matching avoids duplicate policy. Current pure zero-edge
  production callers retain their explicit wrappers; generic phase tests adopt IO.
- The Cluster and Provider.Alias call sites pass their actual complete snapshots directly, without
  pre-sealing or performing a second traversal. Preserve their dependency order and successful payloads.
- The sealed set's producers are private implementation details of preparation. Its plan, operation
  and call-digest binding cannot be replaced by a caller; wrong gates and invalid coordinates still
  refuse before probe IO, and observations must match the descriptor's exact derived edge order.
- "operation preparation rejects an omitted plan dependency" calls canonical withPreparedOperation
  with dependentTestPlan's core:copy-source descriptor, its gate, and a snapshot missing core:deploy-vm.
  Require the exact Failure detail "no managed resource for plan dependency core:deploy-vm of
  core:copy-source" from preparation itself, with no pair or callback.
- The public export list hides withOperationPreconditions and zeroDependencyPreconditions. Capture
  the genuine missing-export diagnostic before registration, preserve the constructor/pair-role
  proofs and hold the exact public export inventory; list new fixture paths only after they exist.
- Align lifecycle, unrepresentable-state and testing docs, and remove only the resolved retainable-set
  ledger row after actual export closure. Keep journal, live-session, consumed-permit, terminal
  advance and retained-readiness limits from Sprint 11.4 and fresh-probe controls from Sprint 11.6.
- Keep these canonical APIs and their two call-site adoptions within 400 changed production lines across
  the three listed modules; signatures outside this owned surface retain their declared contracts.

#### Validation

The counted ready/not-ready and pre-probe refusal controls reach canonical withPreparedOperation.
Generic phase preparation also exercises a genuinely dependency-bearing snapshot with receipt/
transition checks, exact fresh readiness and matching phase indices; the pure zero-phase entry
continues to reject that nonempty descriptor. This holds full phase capability rather than only its
currently used zero-edge subset.
The omitted-dependency case must fail if its traversal missing-member refusal is deleted; an earlier
zeroDependencyPreconditions refusal cannot satisfy it. Run the exact Cluster/Alias success and
refusal regressions, plan/gate mismatches, complete ordered dependency checks and empty-edge controls.

CompileFailSpec must observe and register the complete diagnostic `Module 'HostBootstrap.Reconcile'
does not export 'withOperationPreconditions'` at a genuine public import. Retain ForgePreconditionSet,
ForgePreparedGate and MismatchPreparedPairRoles with live, well-typed subjects. No unavailable symbol
or unrelated String/Text mismatch may mask the intended boundary. Run sealed inventory,
DocValidatorSpec and the complete four-command host-static gate on both hosts before closure.

#### Remaining Work

Adopt the canonical operation and generic phase IO/snapshot signatures in Reconcile, Cluster and Alias,
hide the public retained-set
producers, make the omitted-dependency control reach its exact traversal failure, capture/register
actual compiler diagnostics, align docs and the resolved ledger row, and record all declared gates.

### Sprint 11.8: Canonical provider-share preparation [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/engineering/testing.md`, `DEVELOPMENT_PLAN/rationale.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

The remaining provider-share caller reaches the canonical fresh preparation boundary. The final
surface has the generic fresh operation/phase family and explicit pure zero-edge operation/phase
family, with one shared observation/matching policy and no duplicate alias. This final call-site
adoption is not started. Provider/backend and live
hardware confirmation remain owned by their provider and cluster-lifecycle phases; this stage
holds the lower preparation contract and compiles the existing consumers.

#### Deliverables

- Provider-share preparation calls canonical withPreparedOperation with its full snapshot and gate.
  Its fresh observations, ordered dependencies, successful payloads and exact refusals are unchanged.
- Reconcile has one shared fresh snapshot implementation and no duplicate fresh alias. Exact
  export/definition inventory holds the generic operation/phase family and both permanent pure
  zero-edge wrappers; full dependency-aware phase preparation remains available.
- Readiness's dependency-probe Haddock names the canonical prepare boundary as the place that runs
  the plan-owned probe, preserving its generation/observation-version checks and backend-probe limits.
- Lifecycle/testing docs describe the canonical final paths; a named rationale explains the owned
  observation boundary for any absence guard. Remove only an actual resolved bridge ledger row.
- Preserve prepared-pair privacy, journal/live-session/fence revalidation, terminal OperationAdvance
  behavior and every counted fresh-observation control. This stage budgets 400 changed production
  lines across three modules and adds no backend or authority producer.

#### Validation

ProviderReconcileSpec and ReconcileSpec retain the actual ready/not-ready, gate-first zero-probe,
complete-snapshot and exact pair controls under the canonical provider-share call. Exact export and
definition inventory require the final generic operation/phase and pure empty-edge families; any scoped
absence guard cites its named rationale. The actual source and exports carry no duplicate alias.

Run these focused controls, SessionSpec, compiler boundaries, sealed inventory, PortabilitySpec and
DocValidatorSpec, then all four host-static commands on both hosts. Finally rerun Phase 11's own
exact `cabal test all` from `core/`, record fresh in-gate evidence and close the phase only when every
sprint has no remaining work. No live provider or hardware confirmation is inferred from these runs.

#### Remaining Work

Complete the canonical provider-share adoption and single-entry implementation/inventory, align
Readiness's Haddock and lifecycle/testing/rationale descriptions, remove any actually resolved bridge
ledger entry, and record all four static commands plus the phase's exact core gate before closure.

## Remaining Work

- Sprint 11.4: validate the implemented pure zero-edge preparation on Linux and run all four host-static commands on Windows and Linux.
- Sprint 11.5: prove the already implemented token-boundary refusal through exact SessionSpec regressions.
- Sprint 11.6: add gate-first fresh snapshot admission with counted chart/provider-share observations.
- Sprint 11.7: adopt canonical IO/snapshot preparation in Cluster/Alias, hide retained-set producers,
  and prove the exact missing-dependency and compiler refusals.
- Sprint 11.8: finish canonical provider-share adoption, final single-entry inventory and documentation,
  then run the phase's complete declared gates.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — gate coordinate opacity, exact fields, canonical fixture addresses, pure zero-edge and fresh snapshot preparation, the prepare compare-and-swap and the prepared pair.
- `documents/architecture/unrepresentable_state.md` — ordinary gate readers, typed record-update boundaries and private precondition-set producers.
- `documents/architecture/composition_methodology.md` — the plan-minted execution descriptor.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the durable-before-adapter control, counted fresh observations and prepared-pair compiler boundaries.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § CC name this phase as the owner of the prepare gate.
