# Phase 11 — Prepared operations and preconditions

**Status**: Done
**Depends on**: Phase 10 (versioned sessions, the project journal, and durable fences)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate
**Gate evidence**: 2026-10-30 ; MATT-JUNCTION x86_64 Linux CPU container, kernel 6.18.33.2, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

> **Purpose**: Make every external effect require a value whose only lawful origin is one protected
> compare-and-swap taken immediately before it, over freshly re-probed evidence.

## Phase Objective

Prepared adapters consume an inseparable `PreparedOperation`/`PreparedPreconditions` pair inside their
exact typed package. The pair binds scope, plan and resource indices and retains matching target,
operation/call, attempt and journal-version evidence. The surrounding resource handles and receipts
retain generation; `PreparedGate` retains the journal session and fence. Preparation checks the
descriptor's complete ordered preconditions before returning the pair rather than exposing a sealed
set a caller can retain and present later.

These prepared boundaries make checked preconditions a prerequisite of the adapter's input. The
[step-algebra phase](phase-12-step-algebra-and-project-plan.md) owns invocation mode, broker, lease,
revision, verb and frame admission; the
[cluster-lifecycle phase](phase-16-cluster-lifecycle-and-cordoning.md) owns backend-minted probe authority;
and the [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns root
unknown-phase/call-digest binding and closure of the unchecked gate writer. Those stronger admission
obligations remain explicit in their owning phases.

## Sprints

### Sprint 11.1: Prepared gate coordinate opacity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
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
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared.hs`,
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

### Sprint 11.4: Zero-dependency prepared pairs [Done]

**Status**: Done
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
precondition set. Existing zero-edge checks and pure start/phase/provision wrappers share that
single admitted boundary. The existing Provider and Colima
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
- At the time of these focused runs, the four-command host static gate had not run against this
  sprint's tree on either host. Those focused results alone do not close the sprint or phase.

2026-10-29: The complete four-command host static gate passed on MATT-JUNCTION, native Windows 11
Pro x86_64 (10.0.26300), GHC 9.12.4 and Cabal 3.16.1.0. From `core/`, unfiltered `cabal test all`
passed all 3,554 core cases in 367.93 seconds. From `demo/`, unfiltered `cabal test all` passed the
demo suite and all 3,554 included core cases in 364.56 seconds. Both parent commands exited zero;
the runtime durations name the core suite, not compilation. From the repository root,
`poetry run python -m hostbootstrap.check_code` passed Ruff, Black and mypy, and
`poetry run python -m hostbootstrap.test_all` passed all 376 cases in 7.04 seconds with 100% line
and branch coverage. Source and test bytes remained unchanged throughout these runs. The provider-live
component reported its default not-requested branch; no live-provider result is claimed.

The initial Python invocations did not reach the suites: the new Poetry environment lacked Ruff,
and simultaneous first-use environment creation refused an existing Include directory. After
`poetry install --with dev --no-interaction`, both complete Python commands passed as recorded above.
These environment-setup failures are not test failures or a production change.

2026-10-29: The first focused Linux x86_64 CPU-container run failed 1 of 465 cases in 27.75 seconds
(parent exit one). ColimaSpec's "the shipped command transaction kills its group on hard parent
death" reported process 9111 present after 5.02 seconds. Its actual `/proc/9111/status` was
`State: Z (zombie)`, `PPid: 1`; runner 9109 was also a zombie, and PID 1 was `sleep infinity`.
This container lacked an orphan-reaping init. The unchanged test is owed again in a container
started with `--init`, as required by the gate-host environment. No test assertion or process-kill
implementation is changed on this evidence.
The first unfiltered Linux demo attempt was stopped while its included core suite was running in
that same unreaping container (parent exit 137, command elapsed 322.31 seconds); it has no complete
suite result and supplies no passing gate evidence.

The Linux Python checks passed, and all 376 Python cases passed in 5.40 seconds with 100% line and
branch coverage. The first Python suite attempt on a copy without `.git` failed 35 maintainer-authority
checks; restoring the genuine checkout metadata made the unchanged complete suite pass. These Python
passes alone do not close the Linux static gate.

2026-10-29: With the same production and test bytes in the corrected CPU container, all 465 focused
controls passed in 24.78 seconds (parent exit zero), including the real Colima hard-parent-death case,
ReconcileSpec/ClusterReconcileSpec/ProviderReconcileSpec, ColimaSpec, SessionSpec, all 19 sealed-export
inventory cases, DocValidatorSpec, ForgePreparedGate, the six RecordUpdatePreparedGate fixtures and
MismatchPreparedPairRoles. The gate host was x86_64 Linux kernel 6.18.33.2, GHC 9.12.4 and Cabal
3.16.1.0, using published `docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64` at pulled digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8` with `--init`.
The detector reported `linux-cpu`; no accelerator was passed into the container.

All four Linux host-static commands then passed. From `core/`, unfiltered `cabal test all` passed
all 3,556 cases in 208.15 seconds; from `demo/`, unfiltered `cabal test all` passed all 165 demo cases
in 1.39 seconds and all 3,556 included core cases in 208.16 seconds. From the repository root,
`poetry run python -m hostbootstrap.check_code` passed Ruff, Black and mypy, and
`poetry run python -m hostbootstrap.test_all` passed all 376 cases in 5.75 seconds with 100% line and
branch coverage. Each parent command exited zero, with no failing test context. The provider-live
component reported its default not-requested branch. The complete Windows and Linux static gates
close this sprint; the failed and interrupted setup attempts above remain recorded.

#### Remaining Work

None.

### Sprint 11.5: The plan-minted execution descriptor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

A step carries a value that names its own node, so it can reach its gate. The plan-minted descriptor
and protected-store token-boundary checks bind that gate and its durable record to one exact operation
identity.

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

SessionSpec's "mkRecordName refuses a namespaced token beginning with a dot" and "mkRecordName refuses
a namespaced token ending with a dot" assert exact `ProtectedInvalid` refusals for `core:.x` and
`core:x.`. Its "a dot-prefixed namespaced operation cannot address an existing path operation" registers
`core/x` in a real open session, then requires the exact `SessionStoreFailure ProtectedInvalid` refusal
for `core:.x`, unchanged existing record bytes and physical version, and an unchanged complete protected
image. These cases and the retained descriptor route controls must pass under unfiltered `cabal test all`
from `core/`, together with the complete host static gate.

2026-10-29: The three exact regressions add 21 lines in one test module; the production descriptor
and parser are unchanged. The six focused controls (the three new cases and the retained own-gate,
cross-plan and plain-versus-encoded cases) passed on native Windows 11 x86_64 in 0.29 seconds and
the Linux x86_64 CPU container in 0.33 seconds, both GHC 9.12.4 / Cabal 3.16.1.0, with parent exits
zero. An initial Windows shell-quoting attempt was refused by Cabal's target parser before any test
ran; the argument-vector launch passed all six controls.

All four Linux host-static commands passed on the same `--init` CPU gate host recorded for Sprint
11.4. Unfiltered `cabal test all` from `core/` passed all 3,559 cases in 244.95 seconds. From `demo/`,
unfiltered `cabal test all` passed all 165 demo cases in 1.67 seconds and all 3,559 included core
cases in 245.63 seconds. From the repository root, `poetry run python -m hostbootstrap.check_code`
passed Ruff, Black and mypy; `poetry run python -m hostbootstrap.test_all` passed all 376 cases in
5.96 seconds with 100% line and branch coverage. Every parent exited zero with no failing test
context, and source/test bytes remained frozen. The provider-live component reported its default
not-requested branch.

2026-10-29: The complete Windows host static gate passed on MATT-JUNCTION, native Windows 11 Pro
x86_64, GHC 9.12.4 and Cabal 3.16.1.0. Unfiltered `cabal test all` from `core/` passed all 3,557
cases in 377.52 seconds. From `demo/`, unfiltered `cabal test all` passed all 165 demo cases in
5.10 seconds and all 3,557 included core cases in 381.99 seconds. From the repository root,
`poetry run python -m hostbootstrap.check_code` passed Ruff, Black and mypy;
`poetry run python -m hostbootstrap.test_all` passed all 376 cases in 6.77 seconds with 100% line
and branch coverage. Every parent exited zero with no failing test context, source/test bytes
remained frozen, and the provider-live component reported its default not-requested branch.
The complete Windows and Linux static gates close this sprint.

#### Remaining Work

None.

### Sprint 11.6: Fresh snapshot admission [Done]

**Status**: Done
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
snapshot. The chart and existing provider-share path adopt that behavior over the plan-derived edge set
and traversal.
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
assert the actual matching pair. A genuine empty-edge descriptor also prepares a matching pair through
the fresh entry while an unused managed snapshot member's counted probe stays at zero; the descriptor
determines the traversal. A first-run not-ready probe returns Left with no pair. Wrong gate
plan/operation and a zero attempt return their exact refusals with probe count zero. Positive journal
versions are proved by real first-write/successor CAS readback, the durable-before-callback control and
the gate constructor/journal-version record-update compiler boundaries. The public gate producer cannot
mint a zero physical version, so no forged runtime gate supplies that negative.
The traversal's missing-member and duplicate-member controls exercise the actual preparation path;
retain "chart preparation refuses a failed readiness reprobe", "chart preparation seals exactly its
ready cluster dependency", and "the traversal seals the resource-bearing edge set it derived".

Run focused counted readiness/traversal, chart and ProviderReconcileSpec controls, SessionSpec,
sealed inventory and DocValidatorSpec, then the unfiltered core gate and all four host-static
commands on both hosts. These controls prove observation timing and complete membership, not a
live backend's implementation or an independent journal transaction.

2026-10-29: The implementation changes 236 production lines across the two declared source modules.
The native Windows `cabal build lib:hostbootstrap-core` passed with the package's `-Werror` policy.
ReconcileSpec's "fresh snapshot preparation" group contains the actual ready-pair, first-not-ready,
pre-probe gate refusal, missing/duplicate member and counted chart controls. Its "fresh preparation
takes the empty-edge branch without probing an unused snapshot member" uses a genuine empty-edge
provider descriptor, an unused managed snapshot entry, a CAS-issued gate, zero probes and one
successful pair-consuming callback. ProviderReconcileSpec's "fresh provider-share preparation" group
exercises the actual share consumer with counted ready/not-ready and gate-first refusal controls.

The completed native Windows focused selection passed all 484 cases in 37.45 seconds (parent exit
zero), including all 16 new controls, retained reconciliation/Colima/session cases, all 19 sealed-export
cases, DocValidatorSpec and the prepared gate/pair compiler boundaries. The source/test tree is frozen
for the complete static gates; that focused result alone does not close the sprint.

2026-10-29: The final Linux focused selection passed the same 484 controls in 23.79 seconds, parent
exit zero. Both complete four-command host-static gates then passed against the final source/test
tree, using the native Windows and `--init` Linux CPU gate hosts and pinned toolchains recorded above:

| Gate leg | Native Windows x86_64 | Linux x86_64 CPU container |
|---|---|---|
| `cabal test all` from `core/` | 3,573 cases, 388.28 seconds | 3,575 cases, 253.45 seconds |
| `cabal test all` from `demo/`: demo suite | 165 cases, 5.09 seconds | 165 cases, 1.61 seconds |
| Same demo command: included core suite | 3,573 cases, 365.01 seconds | 3,575 cases, 250.57 seconds |
| `poetry run python -m hostbootstrap.check_code` from the repository root | Ruff, Black and mypy passed | Ruff, Black and mypy passed |
| `poetry run python -m hostbootstrap.test_all` from the repository root | 376 cases, 5.84 seconds, 100% line and branch coverage | 376 cases, 5.66 seconds, 100% line and branch coverage |

Each parent command exited zero with no failing test context, and source/test bytes remained frozen
through the final runs. The provider-live component reported its default not-requested branch.
These complete gates close the sprint without claiming a live backend or hardware acceptance.

#### Remaining Work

None.

### Sprint 11.7: Canonical snapshot preparation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`,
`core/hostbootstrap-core/test/ReadinessSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgePreconditionSet.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportOperationPreconditions.hs`,
`core/hostbootstrap-core/test/compile-fail/MismatchPreparedPairRoles.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`, `documents/engineering/testing.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

The canonical withPreparedOperation boundary takes a snapshot and performs fresh IO preparation;
its Cluster and guest-alias consumers use that boundary. No caller can retain an authoritative
OperationPreconditionSet and present it later. Existing
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

2026-10-29: The canonical snapshot/IO operation and generic phase APIs, chart/Cluster/Alias adoptions
and private retained-set producers are implemented. The production delta from the completed Sprint
11.6 tree is 111 changed lines across three source modules. Native Windows `cabal build
lib:hostbootstrap-core` passed with the package's warning policy.

The genuine public import in ImportOperationPreconditions compiled before export closure with the
public-main-only GHC arguments and no source fallback. After the library was rebuilt with both
retained-set producer exports hidden, the unchanged import failed with GHC-61689 and the complete
diagnostic `Module 'HostBootstrap.Reconcile' does not export 'withOperationPreconditions'`.
CompileFailSpec registers that measured phrase. ForgePreconditionSet supplies typed Text coordinates
and all four actual set fields; its two independent GHC-01928 constructor refusals for
OperationPreconditionSet and DependencySnapshot were measured and are both required. These compiler
observations alone do not close the sprint.

The expanded native Windows focused selection passed all 587 cases in 46.86 seconds, parent exit
zero. It includes canonical preparation and phase cases, the exact missing-dependency refusal,
ChainSpec, ReadinessSpec, ProviderAliasSpec, retained reconciliation/Colima/session controls, sealed
exports, documentation validation and the named prepared/compiler/coercion boundaries. Linux focused
validation and both complete static gates are recorded below.

2026-10-29: Linux passed the same expanded 587-case focused selection in 31.14 seconds, parent exit
zero. The complete four-command static gate passed on each recorded gate host against the completed
canonical snapshot/IO implementation:

| Gate leg | Native Windows x86_64 | Linux x86_64 CPU container |
|---|---|---|
| `cabal test all` from `core/` | 3,574 cases, 374.20 seconds | 3,576 cases, 228.16 seconds |
| `cabal test all` from `demo/`: demo suite | 165 cases, 5.08 seconds | 165 cases, 1.40 seconds |
| Same demo command: included core suite | 3,574 cases, 360.36 seconds | 3,576 cases, 228.86 seconds |
| `poetry run python -m hostbootstrap.check_code` from the repository root | Ruff, Black and mypy passed | Ruff, Black and mypy passed |
| `poetry run python -m hostbootstrap.test_all` from the repository root | 376 cases, 5.74 seconds, 100% line and branch coverage | 376 cases, 5.58 seconds, 100% line and branch coverage |

Every parent exited zero with no failing test context, and source/test bytes remained frozen. The
provider-live component reported its default not-requested branch. These complete static gates close
the sprint; they do not establish live backend behavior or hardware acceptance.

#### Remaining Work

None.

### Sprint 11.8: Canonical provider-share preparation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgePreconditionSet.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeDependencySnapshot.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceReconcilePlanRoles.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`, `documents/engineering/testing.md`, `DEVELOPMENT_PLAN/rationale.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`, `documents/architecture/readiness.md`,
`documents/architecture/durable_state.md`, `documents/architecture/composition_methodology.md`

#### Objective

The remaining provider-share caller reaches the canonical fresh preparation boundary. The final
surface has the generic fresh operation/phase family and explicit pure zero-edge operation/phase
family, with one shared observation/matching policy, a private precondition-set representation and
no duplicate alias. Provider/backend and live
hardware confirmation remain owned by their provider and cluster-lifecycle phases; this stage
holds the lower preparation contract and compiles the existing consumers.

#### Deliverables

- Provider-share preparation calls canonical withPreparedOperation with its full snapshot and gate.
  Its fresh observations, ordered dependencies, successful payloads and exact refusals are unchanged.
- Reconcile has one shared fresh snapshot implementation and no duplicate fresh alias. Exact
  export/definition inventory holds the generic operation/phase family and both permanent pure
  zero-edge wrappers; full dependency-aware phase preparation remains available.
- The precondition-set representation is private to preparation. A genuine public-import fixture
  proves that boundary, and every retained role-coercion fixture names a public subject and fails
  for its own registered diagnostic; no missing import masks another boundary. The snapshot
  constructor has its own independent fixture so a private-set import refusal cannot hide it.
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
ForgePreconditionSet imports the actual private representation through the public facade and records
the measured missing-export diagnostic. CoerceReconcilePlanRoles retains all publicly nameable role
subjects, with only the private precondition-set subject and its expectation absent; each remaining
binding must still fail for its own complete diagnostic.

Run these focused controls, SessionSpec, compiler boundaries, sealed inventory, PortabilitySpec and
DocValidatorSpec, then all four host-static commands on both hosts. Finally rerun Phase 11's own
exact `cabal test all` from `core/`, record fresh in-gate evidence and close the phase only when every
sprint has no remaining work. No live provider or hardware confirmation is inferred from these runs.

2026-10-30: The final canonical provider-share adoption and private representation change modifies
46 production lines across the three declared modules, measured against the completed Sprint 11.7
tree. Native Windows `cabal build lib:hostbootstrap-core` passed with the package's warning policy.
The actual definition/export guard requires the four generic/pure-zero entries, private set/producers
and no redundant entry or reader, and names the existing rationale heading "Preparation owns fresh
dependency observations".

The genuine OperationPreconditionSet public import with a typed subject compiled on 2026-10-29
before closure. Against the rebuilt private-type library on 2026-10-30, the same public-main-only
arguments produced GHC-61689: `Module 'HostBootstrap.Reconcile' does not export 'OperationPreconditionSet'`.
That observed complete phrase is registered. The independent ForgeDependencySnapshot fixture produced
its GHC-01928 constructor refusal. All 15 remaining CoerceReconcilePlanRoles bindings independently
produced their complete expected GHC-18872 diagnostics; no missing import masked them. These compiler
observations and the library build do not substitute for the complete gates recorded below.

2026-10-30: The final focused selection passed all 614 cases on native Windows in 59.69 seconds and
on the Linux CPU container in 35.96 seconds, with parent exits zero. Both complete static gates also
passed against the final source/test tree:

| Gate leg | Native Windows x86_64 | Linux x86_64 CPU container |
|---|---|---|
| `cabal test all` from `core/` | 3,576 cases, 399.47 seconds | 3,578 cases, 238.66 seconds |
| `cabal test all` from `demo/`: demo suite | 165 cases, 5.10 seconds | 165 cases, 1.63 seconds |
| Same demo command: included core suite | 3,576 cases, 377.75 seconds | 3,578 cases, 232.97 seconds |
| `poetry run python -m hostbootstrap.check_code` from the repository root | Ruff, Black and mypy passed | Ruff, Black and mypy passed |
| `poetry run python -m hostbootstrap.test_all` from the repository root | 376 cases, 5.97 seconds, 100% line and branch coverage | 376 cases, 5.85 seconds, 100% line and branch coverage |

Every parent command exited zero with no failing test context; source/test bytes remained frozen.
The provider-live component reported its default not-requested branch. Completion review also aligned
the readiness, durable-state and composition descriptions with the snapshot/IO API and clarified where
prepared-call coordinates are retained.

2026-10-30: After both hosts' complete static gates passed, the separate phase-closing exact
`cabal test all` from `core/` passed all 3,578 cases in 213.41 seconds, parent exit zero (217.61 seconds
including Cabal overhead). It ran in the same x86_64 Linux CPU container against the final byte-verified
governed documentation, including all 17 DocValidator cases, with no source/test/doc changes during
execution and no failing test context. The provider-live component reported its explicit not-requested
branch. This closes the sprint and the phase's declared gate without claiming live provider or hardware
acceptance.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — gate coordinate opacity, exact fields, canonical fixture addresses, pure zero-edge and fresh snapshot preparation, the prepare compare-and-swap and the prepared pair.
- `documents/architecture/unrepresentable_state.md` — ordinary gate readers, typed record-update boundaries and the private precondition-set representation/producers.
- `documents/architecture/composition_methodology.md` — the plan-minted execution descriptor.
- `documents/architecture/readiness.md` — canonical snapshot preparation and the pure zero-edge family.
- `documents/architecture/durable_state.md` — the alias consumer's single fresh snapshot traversal.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the durable-before-adapter control, counted fresh observations and prepared-pair compiler boundaries.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § CC name this phase as the owner of the prepare gate.
