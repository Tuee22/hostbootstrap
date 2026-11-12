# Unrepresentable Illegal State

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [hostbootstrap_core_library.md](hostbootstrap_core_library.md),
[binary_context_config.md](binary_context_config.md), [ownership_seam.md](ownership_seam.md),
[lifecycle_state_model.md](lifecycle_state_model.md),
[accelerator_daemon.md](../engineering/accelerator_daemon.md), [haskell.md](../languages/haskell.md),
[documents index](../README.md), [README.md](../../README.md),
[../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: State, once, the method this repository uses to make an illegal value impossible to
> construct — and state exactly what that method does not buy.

## TL;DR

- A boundary is a **type**, not a convention, a comment, or a review habit.
- Four techniques carry it: private constructor + validating smart producer; rank-2 continuation;
  closed sum + total eliminator; phantom indices.
- A claim of unrepresentability **ships a compile-fail fixture**. Without one, the claim is a comment.
- A test that asserts the current value of an unsealed field pins whatever that field happens to hold.
  When the held value is wrong, the test makes the defect the contract.
- None of this excludes an external actor, and none of it makes a runtime effect exactly-once.

The normative contract is
[§ HH](../../DEVELOPMENT_PLAN/development_plan_standards.md). This page is its canonical
explanation; individual boundaries cite it instead of re-deriving the method.

The ownership entry's nominal index prevents direct cross-entry values. Hidden clause tokens also
carry the actual protected session, so typed ownership effects consume its live owner-thread check
before any primitive or supplied continuation. Delayed IO closures are refused after normal or
exceptional entry exit and on a foreign thread. The [ownership seam](ownership_seam.md#live-entry-for-typed-clause-effects)
states the runtime boundary and its real-file preservation/retry evidence.

## Current Status

The method below is the target every boundary is held to. These boundaries fall short of it in the tree:

- **One `PreparedGate` producer is public.** The production mints are `withPreparedGate` in
  `HostBootstrap.Lifecycle.Session` and the frame executor's local reification in
  `HostBootstrap.Lifecycle.FrameExecutor`, both through the package-private `mintPreparedGate`. The third
  producer, `recordDurableUnknown`, has no production caller and is exported unchecked from the public
  `HostBootstrap.Lifecycle.Prepared`. Any holder of a `ProtectedSession` can call it with a record key,
  phase text, plan digest, operation key, session, fence, and attempt of its own choosing, so a gate proves
  that some compare-and-swap landed, not that journal admission recorded that operation's durable Unknown.
  The [recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owns
  this gap, because the producer's remaining callers and its compile-fail boundary live in files that phase
  and the providers phase introduce.
- **A Windows host reaps only the direct child.** On Windows both the stop and the kill step of
  `HostBootstrap.Effect.ChildGroup` call `terminateProcess` on the launched child, so the recursive
  process bracket ends that child but neither signals a group nor reaps its descendants, and the fixed grace
  gives no graceful stop. The
  [authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
  owns this gap.
- **The direct-Colima boundary is a library boundary with no in-tree consumer.** No production lifecycle module
  and no demo module imports `HostBootstrap.Ensure.Colima`; the CLI reaches only the backend runner's
  `runShippedCommandEntry`. The
  [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
  builds the adapter as a library boundary and assigns only cluster call-site adoption to the
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) and the
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). No phase schedules a direct-Colima consumer,
  because the worked demo's Apple Silicon path provisions through Lima; the adapter's live coverage is the
  direct-Colima lane of the
  [Apple Silicon substrate phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md).

Phase status is tracked in [the development plan](../../DEVELOPMENT_PLAN/README.md).

## Why this page exists

The repository has applied this method at nearly every boundary it has built — and had never stated it.
It appeared as local prose at each site (`AbsExe` "makes a bare command name unrepresentable", readiness
"forged readiness … is unrepresentable at the new boundary", the opaque `StepPlan`, the private
`CanonicalProjectRoot`), and was grounded normatively only in § EE, which is scoped to capabilities and
lifecycle-state tokens, and § CC, which is scoped to readiness.

The cost of having no general statement is not stylistic. Each new boundary re-derived the method from
whichever neighbour its author happened to read, and a boundary nobody thought to seal simply had none.
The host-daemon launch was that boundary: a plain `CreateProcess` record assembled at a call site, with
a stdio disposition that closed the child's descriptors. Every gate passed. One of them asserted the
defect.

## The method

### Private constructor, validating smart producer

The constructor is absent from every exposed module — including any module merely *named* `Internal`.
The producer validates and is the only way in. A record type also keeps its field names out of every
exposed export list, because an exported field admits record update without the constructor.

`HostBootstrap.HostTool.AbsExe` exposes its admitted path through the ordinary function `absExePath`.
`mkAbsExe` rejects a non-absolute path, and `RelabelAbsExe.hs` requires the record-update attempt to fail
because that reader is not a record field.

`HandoffBinding` keeps its thirteen record labels private and exposes ordinary functions under its
existing reader names. `UpdateHandoffBindingField.hs` refuses replacement of the child-frame field;
`RelabelHandoffBindingGeneration.hs` refuses a type-changing phase-field update. Both unchanged
public-only subjects compile before sealing and receive the measured named record-field refusal
afterward. The [binding rationale](../../DEVELOPMENT_PLAN/rationale.md#handoff-bindings-retain-their-admitted-fields)
connects these proofs to the public parser, token-commitment, redaction and narrow key-read controls.

`HostBootstrap.Step.ProjectStepId`, `HostBootstrap.Readiness.PollPolicy`, and
`HostBootstrap.Lifecycle.Prepared.PreparedGate` are the same shape at increasing stakes — the last of
these is minted only through the package-private `mintPreparedGate` after a durable Unknown compare-and-swap,
and `ForgePreparedGate.hs` pins the constructor's absence from the public export. Its six coordinate
readers are ordinary functions. The typed `RecordUpdatePreparedGatePlan.hs`,
`RecordUpdatePreparedGateOperation.hs`, `RecordUpdatePreparedGateSession.hs`,
`RecordUpdatePreparedGateFence.hs`, `RecordUpdatePreparedGateAttempt.hs`, and
`RecordUpdatePreparedGateJournalVersion.hs` fixtures refuse replacement through each reader. Its public
producer is recorded in [Current Status](#current-status). The root's journal admission,
`withPreparedGate`, mints it directly
after its CAS;
a storeless `FrameExecutor` may reify the same gate only through that hidden allow-listed mint after exact
comparison of the root-signed prepared response's node/dependencies/operation-gate/projected-gates packages
with its local `ExecutionNode` and durable coordinates.

The [private authority kernel](../../core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs)
also gives the command-reservation boundary four descriptive coordinate types: `CommandPlanDigest`,
`CommandFrameName`, `CommandProjectName` and `CommandStoreIdentity`. They remain distinct in reservation
fields, origin comparison and canonical identity framing. Callers wrap at the actual read point;
the kernel unwraps for equality checks and UTF-8 encoding. Public Main facades expose none of these
types or constructors. `AuthoritySpec` holds the signatures, fields and export boundary alongside the
unchanged reservation-byte and invocation-key assertions.

The same kernel validates a retained opaque `BrokerEpoch` against its live allocation. It checks the
actual session's store first, then the retained project's counter through the allocator's private key
and decoder. The validator reads only; it neither reifies an epoch nor repairs missing or corrupt
state. It is absent from the public authority and testing facades. `AuthoritySpec` holds current,
rotated, missing, corrupt and foreign-store cases with complete protected-store before-images, plus
the [private ownership rationale](../../DEVELOPMENT_PLAN/rationale.md#broker-allocation-remains-owned-by-its-kernel).

The root's own `PreparedNodeGrant` is the same idea one level up, and it is built. It carries the authorized
node, that node's ordered dependencies, and the two gate packages — and no request, response, store, session,
record key, or compare-and-swap operation, so its evidence fold discloses what a frame may
do without disclosing how the root recorded it. Its producer cannot reach the constructor until every exact
durable unknown row is published and strictly read back, the node's own first and then each projected
operation in the catalog's order, so a partially prepared node yields no grant rather than a grant claiming
more than was prepared. The live endpoint renders and signs `Prepared` only from that post-publication evidence;
`Descend` and `Refused` are
different response families with no constructor on that path, which is why "the root told me to descend"
cannot be mistaken for "the root authorized this effect". The grant carries gate *packages* rather than
`PreparedGate` values, so it mints nothing and the hidden mint allowlist is unchanged.

The owner that prepares and settles reaches a frame session only through that session's fixed-unit coordinate
fold. It never receives the session's record key, version, or row bytes, so advancing or rewriting a session
is not something it declines to do — it is something it has no term to express. Every durable row it writes
is one it derived a key for itself, and settlement's row carries the session ordinal in its key, so settling
one node twice at one ordinal converges on the record already present while two ordinals address two rows.

### Rank-2 continuation

Some values are only meaningful inside the scope that authorized them. A rank-2 bracket binds a fresh
type variable the caller cannot instantiate, so the value cannot be returned directly across that
scope. An IO closure can retain the original value; effects needing operational lifetime also check
the bracket's private live token and owner thread.

`withProtectedEntry`, `withCanonicalProjectRoot`, `withInstalledProjectIdentity`, and the composite
Production/Harness root brackets all do this. It is what makes "this handle belongs to the entry,
root, installed binary, or broker generation that opened it" a type error rather than a comment.

### Closed sum, total eliminator

An outcome set is a closed sum, and it is consumed by an eliminator with no wildcard. Adding a case is
then a compile error at every site that must decide about it.

`CaseResult`'s three eliminators — `caseResultPassed`, `caseResultLabel`, and `caseResultReason` — are all
total, and `caseResultPassed` is documented for exactly this reason: "so adding an outcome cannot silently
be counted as success". `TeardownOutcome` and `ReconcileError` in the core, and the demo's `DaemonEvent`,
are the same shape. A wildcard in an eliminator is the defect this technique exists to
prevent — it silently absorbs the case nobody considered.

### Phantom indices

A `scope`, `planId`, `runId`, or `resource` index costs nothing at runtime and makes cross-plan,
cross-scope, and cross-resource mixing a type error only when the carrier's role is nominal. GHC otherwise
permits `coerce` across a phantom or representational parameter even when the constructor is hidden.
`LifecycleProfile (Production projectId)` versus
`LifecycleProfile (Harness projectId runId)` is the load-bearing instance: a test component has no
route to a Production profile because there is no term of that type it can reach.

`LifecycleCursor scope planId frame brokerGeneration verb phase` is the six-index durable instance.
Every role is nominal, its constructor is hidden, and its only public producer consumes the matching
`AcquisitionJournal` plus `ProjectFrame`. The public successor surface contains only
`Prepare -> Execute -> Teardown`; there is no function whose input can skip Execute, change the verb,
advance Teardown, or reinterpret one frame/broker/plan cursor as another. Existential recovery does not
weaken that relation: `withCurrentLifecycleCursor` quantifies the phase itself and delivers the matching
phase witness and cursor together.

The cursor also retains its original acquisition journal's Mode-owned live validator. Fresh opening,
resume and successors preserve that same private closure; there is no public validator selector or
replacement. `withLifecyclePrepareEntry` checks it and the exact command/cursor/descriptor coordinates
before its accepted action. Chain invokes the fixed entry before initial journal bookkeeping and
before every node's registration and preparation. Its scoped flow guard and actual no-write refusals
hold the [prepare admission boundary](../../DEVELOPMENT_PLAN/rationale.md#prepare-admission-rechecks-the-retained-live-binding).

Canonical record admission also checks bounded UTF-8 frame bytes and the complete payload before a
valid unequal durable binding can reach the collision refusal. Exact resume retains the current row
version without rewriting it; [the lifecycle state model](lifecycle_state_model.md#lifecycle-profile-authority)
owns these byte and durable-record rules.

`ReverseRootIntent projectId sourceBrokerGeneration verb` is the durable reverse-root instance. All three
roles are nominal, its constructor is module-private, and its closed GADT has Pending, Committed, and
Terminal cases for Down and Destroy. The root snapshot facade admits only an exact same-verb source or
resume under root liveness; the canonical codec retains project, store, plan, broker and record-version
coordinates. Ordinary admission refuses a conflicting live intent. Only the sealed root lifecycle entry
can consume the recovered authority. Children receive authenticated recovery packages and storeless grants.

The reconciliation boundary applies the same rule exhaustively. `StepExecution`, `StepRuntime`, and
`ResourceCarrier` make both `scope` and `planId` nominal; `ResourceHandle` makes scope, plan, resource
identity/kind, ownership, and phase nominal; and the receipt, adoption, dependency, prepared-operation,
result, journal-proof, and phase-transition families make every identity or typestate parameter nominal.
Thus an equal runtime representation cannot turn a foreign observation into managed ownership, pair the
halves of different preparations, or relabel one plan's carried resource as another's.

`PhaseAdvance` has one public producer: `completePreparedPhaseTransition`, whose input is the opaque
matched `PreparedPhaseTransition`. The generation-check helper remains private. The public-only
`ImportVerifyPhaseTransition.hs` subject holds its missing-export boundary, while actual reconciliation
and Chain cases complete the canonical prepared route with their existing generation, receipt and
settlement-version controls. The [prepared-pair rationale](../../DEVELOPMENT_PLAN/rationale.md#phase-advances-complete-a-prepared-pair)
separates this pure completion boundary from the lower gate-producer admission described in
[Current Status](#current-status).

The carrier representation is compiled once in the private `lifecycle-representation-internal` unit.
Main and both test components share that identity. `ResourceCarrierCore` makes scope, plan and dependency
payload nominal; main's alias binds the payload to its own runtime-dependency package. The public
allocator refusal is held by `ImportResourceCarrierAllocator.hs`; `ImportLifecycleExecutionCore.hs`
requires the private-unit visibility refusal and compiles when only the selected unit changes.
`CoerceResourceCarrierCoreRoles.hs` runs with that private unit visible and checks all three roles using
representationally equal newtypes. The six public execution-role controls remain independent.

The same unit owns `StepRuntimeCore`, whose scope, plan, gate and dependency payload are all nominal.
Its actual factory initializes the own, available and taken gate references plus the shared carrier;
main keeps the real prepared-gate operation comparison and state transitions. `CoerceStepRuntimeCoreRoles.hs`
checks all four roles with that unit visible. `ImportStepRuntimeAllocator.hs` and
`AssembleStepExecutionWithPublicRuntime.hs` hold the public allocator and descriptor-assembly refusals.
The actual `ImportLifecycleRuntimeCore.hs` fixture fails under main-only visibility and compiles when
only the selected private unit changes. No duplicated gate type or injected selector supplies the test route.

Canonical operation and generic phase preparation accept a dependency snapshot and own its fresh
traversal in IO. The sealed set's traversal and empty-set producers are private;
[`ImportOperationPreconditions.hs`](../../core/hostbootstrap-core/test/compile-fail/ImportOperationPreconditions.hs)
pins the genuine missing-export boundary. `ForgePreconditionSet.hs` requires the private set's
missing-export diagnostic; `ForgeDependencySnapshot.hs` independently requires its snapshot-constructor
refusal. No missing type import can mask that constructor proof. `MismatchPreparedPairRoles.hs` keeps
the jointly returned operation/preconditions pair indexed by the same operation and attempt.

The interpreter-carried `PlannedStepObservation scope planId configId` likewise makes all three roles
nominal. The backend-facing `StepObservation` remains deliberately plan-independent and non-authorizing;
the public plan facade wraps only the selected node's checked `runPlannedStep` dispatch result,
including descriptor refusal before its callback, before Chain classifies or settles it. The constructor
is private, and scoped definition/export guards hold that sole producer boundary with the named public
reference compiler refusal. This proves scope, plan, and
configuration continuity, not a separate node identity: exact Chain supplies the matching planned node and
descriptor at the call site, while the wrapper itself has no node index.

Current-frame Chain's four runtime evidence refusals are owned by the private compiled `EntryPolicy`,
with actual authority/store values and Main's genuine cursor/topology projections. Its `VerbUp` and
`ExecutePhase` constraints remain static; `CrossAuthorityChain.hs` and `CrossCursorChain.hs` each exercise
all six actual entry-call index mismatches. Runtime tests call Chain itself with genuine evidence,
checking exact errors and unchanged complete protected record images; a pure policy call alone does
not prove the effectful boundary. [Binary-context admission](binary_context_config.md) owns the checks.

`HarnessAuthority projectId runId` and `HarnessConfigAuthority projectId runId` make both indices nominal.
The public Harness authority retains its descriptive run text; the narrower configuration authority is an
opaque token without a stored copy of that text. Their hidden constructors and run-index coercion fixtures
hold the scope boundary even when their runtime representation carries no index:
[CoerceHarnessAuthorityRun.hs](../../core/hostbootstrap-core/test/compile-fail/CoerceHarnessAuthorityRun.hs)
and [CoerceHarnessConfigAuthorityRun.hs](../../core/hostbootstrap-core/test/compile-fail/CoerceHarnessConfigAuthorityRun.hs).

The project-mode boundary likewise uses empty `ProductionMode` and `HarnessMode runId` type tags,
with a nominal Harness run parameter. They have no term constructors to expose. The real capability is
`ProjectModeLease projectId mode brokerGeneration`, whose constructor is private and all three indices
are nominal. A protected mode transition produces it; the private wire sum and generic mutation kernel
do not cross the public facade. Constructor privacy and mode/run coercion are separate proof obligations.

The journal carriers `ProjectPermit`, `ClosingProjectPermit`, `ClosedProjectPermit`, `OperationSession`
and `OperationAdvance` each make scope and plan nominal. Ten newtype-alias probes hold the two axes
independently, while a positive payload-coercion control preserves `OperationAdvance`'s representational
result. This prevents relabelling an already typed value through `coerce`; it does not authenticate the
raw plan text accepted by `openProjectJournal`. That generic producer still permits caller-selected
scope and plan instantiation. Journal versions govern runtime exclusion, and higher admission bridges
perform their own plan joins. Deterministic same-permit order controls and cross-process exclusion are
distinct evidence.

`VerifiedAllSessionsClosed scope planId` is an abstract observation with nominal scope and plan roles.
Its two newtype-alias probes hold each axis independently. The generic `verifyAllSessionsClosed`
producer accepts raw plan text and caller-selected result indices; nominal roles do not authenticate
that text, scope or store identity. Consumers retain their runtime bound-lease plan comparison. The
exact export inventory holds the existing abstract boundary, while its dedicated constructor-forgery
compiler proof remains owned by the
[recovery-and-migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md).

`FenceEpoch scope planId` likewise keeps both roles nominal behind its private single-field constructor.
Its newtype-alias probes target scope and plan separately, and `ForgeFenceEpoch.hs` uses the actual
constructor shape. `OldPermitsFenced scope planId` also keeps both roles nominal behind its private
constructor, with a newtype-alias probe for each axis. Nominal value separation does not authenticate
the raw plan text accepted by the generic `currentFence`, `establishInitialFence`, and `fenceOldPermits`
producers or constrain their caller-selected indices. The fence set's protected-entry index remains
owed by the [recovery-and-migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md).

`IntentOrigin` exposes the lawful absent-record choice `NoHistory`, while its released variant is private.
`readReleasedIntentOrigin` observes ordinary `Released` at the operation session's derived key and retains
the store identity, key and physical record version. Registration re-reads all of them and the phase before
its existing transaction; another key/store, a changed or missing record, or `AdoptionReleased` cannot
supply that origin. This proves the recorded observation's eligibility, not complete payload validation
or backend history. An absent new key uses `NoHistory`, not an origin copied from an old released key.
The actual hidden-constructor child import is `ForgeReleasedIntentOrigin.hs`.

Indices are only as strong as the values that carry them. An index on a type whose every accessor
returns plain `Text` is documentation, not enforcement — worth writing when a future consumer will
need the pairing checked, but it should be described as such until then.

The private [rooted codec](../../core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs)
owns its own `PayloadDigest` for the complete payload commitment. `mkPayloadDigest` checks exactly 64
lowercase hexadecimal characters through the existing digest validation; `payloadDigestText` is its total
eliminator. The constructor stays hidden. The monomorphic scalar has no parameter roles; its `Eq` and
`Show` instances describe inert DATA and grant no signing, session or command authority.

`ChildConfigDigest` separately brands the exact child-config commitment. `mkChildConfigDigest` reuses
the existing child-config digest predicate; `childConfigDigestText` is its total eliminator. Its
constructor stays hidden, and it is monomorphic inert DATA. The two roles remain distinct even when
their canonical text is equal. Scalar construction validates format; Handoff supplies byte provenance.

Both private payload kernels retain the two checked roles in the binding fields, getters and unsigned
rendering. Handoff wraps actual computed SHA values only after its existing broker, kind, byte, edge
and recovery-conflation checks, wrapping payload before child config in the existing validator tuples.
The public `Text` descriptions eliminate their respective scalars. Decoding preserves the existing
payload-before-child-config validation order. Signed bytes and fixed cryptographic wrappers keep
their existing contract; no raw compatibility kernel is added. Lifecycle coordinate roles remain
separate input contracts. Source preservation names unchanged request/response shapes and codec/framing
declarations independently of this payload representation.

`RequestDigest` separately brands the digest of the exact rooted lifecycle request bytes.
`mkRequestDigest` admits exactly 64 lowercase hexadecimal characters through the existing request
digest predicate; `requestDigestText` is its total eliminator. Its constructor stays hidden. This
third monomorphic scalar is inert DATA, with `Eq` and `Show` and no signing, session or command
authority. It remains distinct from the payload and child-config roles even when their text is equal.

The six post-open unsigned response builders for `Prepared`, `Descend`, `Settled`,
`FrameComplete`, `ReceiptRecorded` and `Refused` accept `RequestDigest` in their request slot,
as does the private opaque-response builder. Canonical reconstruction smart-wraps the digest after
its existing raw validation. Relay's prepared and post-open response callers wrap the SHA of the
exact existing rendered request after each caller's attached-session and post-open checks, inside
the existing validation result. Prepared also retains its grant fold. Signing, callback timing and
IO order retain their contracts.
`Opened`, raw common validators, response DATA shapes, descriptive folds and request pairing keep
their `Text` contracts. Nonce-only `OpenFrame` and the five post-open request builders retain their
separate input contracts. Scalar construction checks format and role; the Relay caller supplies
the exact-request provenance.

`LifecycleSession` separately brands the session input of the same six post-open response builders
and their private opaque helper. `mkLifecycleSession` reuses the existing `response session`
check: the text must be nonempty and its UTF-8 encoding must occupy at most 4096 bytes.
`lifecycleSessionText` eliminates the accepted text exactly. The hidden constructor and monomorphic
`Eq`/`Show` scalar describe inert DATA; they grant no session or signing authority.

Format admission is separate from provenance. The retained frame-session producer derives its
existing 64-character ASCII token by hashing the framed identity, and attach/advance preserve it.
Relay's two response callers construct `RequestDigest` first, then check that retained token with
`mkLifecycleSession`, inside the existing validation result after each caller's attached-session
and post-open checks; Prepared also retains its grant fold. Canonical decoding wraps the session
after its existing raw validation. Response shapes, raw common validators, `Opened`, descriptive
folds, request pairing and request builders retain their existing `Text` contracts. The session
input role changes no producer authority, error priority, callback timing or IO order.

`LifecycleStage` is a fifth inert scalar, distinct from `LifecycleSession`. Its hidden constructor
is reached through `mkLifecycleStage`, which reuses the existing `response stage` check: nonempty
text occupying at most 4096 encoded UTF-8 bytes. `lifecycleStageText` returns that text exactly.
The format check imposes no enum or membership policy and grants no authority or state transition.

The six post-open response builders and private opaque helper take this checked stage as input;
canonical reconstruction wraps it only after existing raw stage validation. In each existing Relay
validation result, `RequestDigest` is constructed first, `LifecycleSession` second and
`LifecycleStage` third, after the caller's attached-session/post-open checks and Prepared's grant
fold where applicable. Prepared uses its existing `prepared` literal; generic responses use their
existing closed family selection, preserving that operation's separate refusal of Prepared.
The ignored stored-session stage supplies neither value. `Opened`, common validators, DATA shapes,
descriptive folds, pairing and request builders retain their `Text` contracts. Error priority,
callback timing and IO order keep their existing scope.

`LifecycleOrdinal` is the sixth inert scalar. Its hidden constructor is reached through
`mkLifecycleOrdinal`, which accepts `Word64` values from 1 through `maxBound`; zero retains
the response error `has a zero response ordinal`. `lifecycleOrdinalWord64` eliminates exactly.
The monomorphic `Eq`/`Show` DATA value has no numeric-construction instance and grants no
authority, monotonicity or lifecycle transition. Ordinary `Word64` successor arithmetic still wraps
`maxBound + 1` to zero, and that zero keeps the existing refusal; no overflow policy is added.

The six post-open response builders and private opaque helper take a checked ordinal. Canonical
reconstruction wraps it only after the existing raw ordinal width/nonzero validation, whose separate
`has a zero ordinal` error remains. Prepared wraps its existing successor after the prior evidence
and RequestDigest/Session/Stage checks. The generic caller selects its response family before any
ordinal construction; only selected arms or their opaque helper wrap the successor. Its unchanged
wildcard therefore keeps the generic-family refusal first, even when the successor is zero.
These input checks leave `Opened`, common validators, DATA shapes, descriptive folds, callbacks,
request pairing and request-builder ordinal values as `Word64`, with their existing IO order.

`PredecessorDigest` is the seventh inert scalar, used only for `ReceiptRecorded`'s final
completed-response commitment input. `mkPredecessorDigest` applies the existing `completed response`
predicate for exactly 64 lowercase hexadecimal characters; `predecessorDigestText` eliminates
the accepted text exactly. Its hidden constructor and monomorphic `Eq`/`Show` DATA grant no
authority and do not establish the relationship to a request predecessor.

Canonical receipt reconstruction wraps that commitment after its existing raw validation and checked
ordinal. Relay wraps only the receipt arm's existing lenient UTF-8 body interpretation, after
checkedOrdinal, preserving wrapped-zero refusal before malformed completion. Other generic Relay report
and refusal inputs retain `ByteString` contracts. The existing terminal-report publication supplies
the SHA of the actual signed `FrameComplete`; the unchanged pair verifier compares the receipt's
completed commitment with `ReceiptConfirm`'s predecessor. These provenance and pairing checks
are separate from scalar format admission. Raw request predecessors, descriptive callbacks/folds,
DATA and `Opened` keep their existing contracts and authority boundaries.

## Activation manifest construction

`ActivationManifestInput` is plain DATA with twelve coordinates: ten descriptive `Text` values,
the existing opaque `ActivationSecretDigest`, and an ordered effect list. Its distinct input labels
feed `activationManifest`, which constructs a candidate and runs the existing `validateManifest`
before returning it. Input construction itself establishes no signing or effect authority.

The producer requires nonempty scope, plan/spec/binary digests, frame, rollout revision, config
digest, service identity, role-plan digest and secret-channel locator. Each supplied effect identity
must be nonempty and distinct. An empty effect list is valid, and the supplied order is preserved.
Digest-shaped descriptive fields may contain non-hexadecimal text; this producer adds no path,
instance, provenance or blanket secret-free rule. The dedicated secret field retains its existing
opaque digest contract.

The demo's private `prepareDemoServiceActivationFor` supplies this input from its existing
selected service coordinates and forces `activationManifest` through
`either (die . activationErrorMessage) pure` before rendering for signing and installing the revision.
Earlier caller daemon-stop, binary-install and measurement effects, and `StepExecution` construction,
retain their order. Current callers supply validated nonempty measurements; empty-rollout DATA
controls and the source join do not demonstrate an actual command's refusal.

`ActivationManifest` is abstract. Its twelve public field names are ordinary total getters; private
record labels stay hidden, so a record update cannot bypass checked construction.
`activationManifestFromWire` returns a manifest through the same producer only after the existing
structural decoder has accepted the frames, text, secret digest, effects and trailing-byte boundary.
Every successfully decoded manifest therefore satisfies the same semantic requirements. These
checks establish no provenance or authority. The manual `Show` retains the public field spellings,
precedence and redacted secret digest; canonical rendering and signature material retain their
existing contracts.

`SelectedActivationManifest` assigns a distinct selected-input DATA role to an already validated
manifest. Its constructor stays private; total `selectedActivationManifest` assignment and ordinary
`selectedActivationManifestValue` elimination retain that validated value. The canonical verifier
requires this role at its selected-input position and unwraps it before its existing ordered checks.
Role assignment alone establishes no independent selection provenance, signature or effect authority.

`ReceivedActivationManifest` assigns the separate received-input DATA role through total
`receivedActivationManifest` and ordinary `receivedActivationManifestValue` elimination. Both roles
carry already validated manifests; neither proves selection or transport provenance. Their distinct
opaque types prevent direct transposition at the canonical verifier's adjacent selected/received
positions. Both unwrap before its existing ordered validation, comparison, signature and store checks.

`BuildProjectName` gives the build binding's project field and canonical verifier input a separate
opaque DATA role. Total `buildProjectNameFromText` assignment and ordinary `buildProjectNameText`
elimination add no format, nonempty or provenance rule. The role's `Show` delegates to the underlying
text, preserving existing binding display and canonical eight-field bytes. Independent key, signature,
source/builder measurements and the authority's nominal indices remain separate runtime checks.

`BuildSpecDigest` separately marks the build binding and verifier's specification coordinate.
Total `buildSpecDigestFromText` and ordinary `buildSpecDigestText` retain descriptive text, including
empty and non-hexadecimal values; runtime identity and authority checks remain at verification.
Its text-compatible display and wire field preserve the existing binding observations. The distinct
type prevents a raw text value from silently occupying the specification input.

`BuildConfigDigest` marks the separate configuration coordinate through total
`buildConfigDigestFromText` assignment and ordinary `buildConfigDigestText` elimination. Like the
specification role it preserves descriptive text and its display, without new format or provenance
checks. Their distinct opaque types reject a direct spec/config transposition at both actual
adjacent verifier positions; existing runtime validation and authority indices remain separate.

`BuildIdentifier` marks the binding field and the authority's stored description through total
`buildIdentifierFromText` assignment and ordinary `buildIdentifierText` elimination. Empty and
arbitrary text remain representable DATA. The existing nonempty-ID check stays after coordinator
comparison and before the frame check at canonical verification. Public `buildAuthorityBuildId`
still returns `Text`; authority display, binding display and canonical signed bytes remain compatible.

`BuildSourceDigest` separately marks the binding's source observation and the verified authority's
stored description. Total `buildSourceDigestFromText` and ordinary `buildSourceDigestText` retain
arbitrary descriptive text without validation or provenance claims. Generic `measureSourceDigest`
still returns `Text`; canonical verification assigns the role to its fresh measurement before the
existing source comparison. Public `buildAuthoritySourceDigest` still returns `Text`. Source bytes,
binding/authority display, signature material and ordered refusal behavior retain their contracts.

`CoordinatorDigest` marks the binding's coordinator field, active coordinator's stored description,
signing input and canonical verifier's separate coordinator input. Total `coordinatorDigestFromText`
and ordinary `coordinatorDigestText` preserve arbitrary descriptive text. The role adds no format,
validity or provenance check. The installed signing key, active bracket and nominal coordinator index
retain their authority contracts. Existing signer/verifier mismatches, wire bytes, signature material
and redacted coordinator display remain compatible.

`BuilderDigest` marks the binding's builder field and canonical verifier's fresh binary observation.
Total `builderDigestFromText` and ordinary `builderDigestText` preserve arbitrary descriptive text
without validity, format or provenance checks. Generic `measureBinaryDigest` still returns `Text`.
The direct binding assigns the role to its shared raw coordinator/builder observation;the VM binding
assigns it to the independent builder measurement. Canonical field bytes, signature material and
existing mismatch order retain their contracts;authority storage and nominal indices stay separate.

`BuildFrameName` marks the binding's frame field and the private frame and phase-authority
descriptions. Total `buildFrameNameFromText` and ordinary `buildFrameNameText` preserve arbitrary
and empty descriptive text. The existing nonempty-frame check stays at canonical verification after
the identifier check and before measurement. Public `imageBuildFrameName` retains its `Text` result.
Binding bytes,frame/authority display and signature material remain compatible;nominal authority
indices and phase-use state remain separate from this DATA role.

`BuildSourceRoot` marks only the canonical verifier's selected source-root path. Total
`buildSourceRootFromFilePath` and ordinary `buildSourceRootFilePath` preserve its `FilePath`,
including empty,relative and absolute descriptions,without validation,normalization or provenance
claims. The role is eliminated at the existing generic `measureSourceDigest` call. It adds no binding
wire field or authority index;fresh measurement and its existing ordered refusals remain the gate.

`BuilderPath` separately marks canonical verifier input seven. Total `builderPathFromFilePath`
and ordinary `builderPathFilePath` retain the existing `FilePath` without validation,normalization
or provenance rules. Generic binary measurement remains unchanged. Distinct `BuildSourceRoot` and
`BuilderPath` values reject direct transposition at both real verifier inputs;the roles add no
binding-wire fields or authority indices and retain existing measurement/refusal order.

`MeasuredInstance` is a separate opaque sum for a pod UID with its `Word64` restart count or a
host invocation nonce. `kubernetesInstance` and `hostServiceInstance` preserve the existing nonempty
UID/nonce checks and exact refusals. Restart zero through `maxBound` and long nonempty nonces remain
valid; the producers add no format, length, provenance or authority rule. `foldMeasuredInstance`
provides total pure descriptive elimination through the pod and host callbacks, followed by the
value. Existing identity text, constructor spellings in `Show` and framed admission-key material
retain their contracts. Verified activation's seven nominal indices and origin-bound admission
remain separate from this descriptive value.

## Project-plan absence guards

These guards are not a fifth type technique. They are lexical source checks that run at test time and
detect drift in the import and export surface a type boundary depends on, which is the drift-guard
obligation [What this does not buy](#what-this-does-not-buy) names.
The [testing guide](../engineering/testing.md#one-toolkit-for-reading-this-repositorys-own-sources)
defines comment-aware fragment matching, actual declaration boundaries and definition-body caller
audits. Source discovery covers every effective library root, including private units and the main
library's backend directory.

The [step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
mechanically guards the project-plan boundary. Its scope is exact and intentionally narrower than the
behavior of every consumer:

- of the snapshot family, the public pure `HostBootstrap.ProjectPlan` facade exposes only
  non-authorizing `StablePlanSnapshot`; public snapshot evidence lives in
  `HostBootstrap.ProjectPlan.Snapshot`, while indexed construction and the canonical encoder remain behind
  the representation boundary;
- the canonical snapshot and stable reporting wrapper have one private shared representation, compiled
  once for main and package tests. Opening the actual admitted stable value inside that package boundary
  yields the same canonical writer input; a second copy or a cast between distinct wrappers supplies no
  such identity proof. The public facade keeps both constructors inaccessible;
- the `ProjectPlanSpec` guard "exactly the audited production modules import the plan kernel" is the single
  source for the production-source importers of `HostBootstrap.Lifecycle.Plan`. It pins nineteen modules:
  the plan facade and its construction, frame, snapshot, handoff, and projection owners; the plan-bound
  authority; the lifecycle mode, session, recovery, context, and rooted-plan modules; `HostBootstrap.Reconcile`;
  the teardown internals; the cluster budget, workload and its binding; and the command lifecycle entry and child
  entry. It rejects any added or missing importer, requires `HostBootstrap.Command.LifecycleEntry`, which owns
  the fixed Chain interpreter and its `SelfRef` input, to import `HostBootstrap.Chain` and `HostBootstrap.Lift`,
  and refuses `HostBootstrap.Lift` to every other importer;
- every Cabal-exposed module has an explicit lexically parsed export list. None exposes the indexed snapshot,
  canonical encoder, hidden kernel, or a `PlannedResource` constructor, and the plan facade is the sole public
  exporter of the plan-owned resource/edge projection routes;
- the object-store family and rollout probe share the actual `ObjectStoreResource` datatype from
  `HostBootstrap.Plan.Resource`. The guard "object-store vocabulary has one private tag and rollout
  relation" holds that sole definition, direct imports, the exact probe relation and public constructor
  re-export, and the absence of product-specific identifier tokens throughout the actual library sources;
- the command-admission source guard counts only the Production fresh-or-recovered plan admission. The
  [test-harness-and-run-ownership
  phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) owns Harness command adoption and
  the assertion-only `TestSuite` boundary; and
- generic `ResourceEnvelope` is projected through optional `BudgetCfg` from the exact plan's retained
  validated configuration; budget admission takes no independent envelope or public raw config getter.
  Production adoption of the demo's workload, overhead, partition, and slices remains
  with the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)'s concrete workload and slice
  projection.

Dated closure evidence remains in the
[step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
rather than being duplicated on this architecture page.

The fence producers take an opaque `ProjectPermit scope planId`, privately retaining its journal
coordinate. `SessionSpec`'s "fence producers retain their held permit indices" holds those signatures,
the private representation and existing nominal roles. `FenceEpochFromOtherPermit.hs` and
`CrossFenceEpochPreparedSession.hs` target producer and gate index mismatches respectively;
the existing scope/plan coercion subjects continue to hold the nominal roles. These are witness-index
proofs, with the runtime boundary described in [lifecycle state](lifecycle_state_model.md).

## The proof obligation

A boundary that claims a shape cannot be constructed ships a compile-fail fixture under
`core/hostbootstrap-core/test/compile-fail/`, registered in `CompileFailSpec`.

Worked examples: `ForgeStepExecution.hs` (a project cannot fabricate a plan-minted descriptor),
`CoerceExecutionRoles.hs`, `CoerceResourceHandleRoles.hs`, `CoerceReconcilePlanRoles.hs`, and
`CoerceReconcileEvidenceRoles.hs` (opaque indices cannot be representation-coerced),
`CoercePlannedStepObservationRoles.hs` (an interpreter-carried observation cannot be relabelled across
scope, plan, or configuration), `CrossAuthorityChain.hs` and `CrossCursorChain.hs` (an exact Chain entry
cannot substitute foreign command evidence),
`CoerceValidatedContextRoles.hs` (all three admitted context indices remain nominal even for
representationally equal scope, plan and frame brands),
`ForgePreparedGate.hs` (a caller cannot name the prepare-gate constructor), `ForgeTeardownForest.hs`
(nor a teardown forest, nor substitute one verb's projection for another's), and
`ForgeProviderWallSettlementPermit.hs` / `ImportBudgetInternal.hs` /
`ImportColimaSettlementInternal.hs` (nor turn a descriptive wall observation into live authority or import
either the provider-neutral mint or owning adapter bridge), and `ForgePreparedProviderStart.hs` /
`ImportProviderStartInternal.hs` (nor manufacture or complete the journal-bound provider start).
Generic reconciliation can still produce a managed provider `ResourceHandle`, including `Running`;
`GenericProviderHandleAsManaged.hs` and `GenericProviderHandleAsBoundExec.hs` pin that this is not
the owning backend's managed wrapper or guest-execution authority. The prepared-start package's
opacity is separate from that generic route.

`CallerFenceProviderWallReservation.hs` and `CrossPartitionProviderWallReservation.hs` pin the related
pre-call rules: a wall, partition, and caller-chosen positive number are not a journal reservation, and a
reservation from another constructive partition cannot enter the call. `ForgeProviderWallReservation.hs`
and `CoerceProviderWallReservationRoles.hs` pin its hidden constructor and nominal plan/fence indices.

Provider-wall settlement permits store only the private success sum `SettledWallObservation`.
The mint admits applied, already-exact and migrated observations only with positive epochs; refusal,
failure, uncertainty and invalid epochs cannot inhabit the permit's observation field. Settlement is
total over those three successful constructors, preserving migrated as `Changed Repaired`. Only
`Cluster/Budget.hs` and `Ensure/Colima/Settlement/Internal.hs` import the private budget module,
and the bridge cannot import its reservation or prepared-call constructors. `BudgetSpec` checks this
complete production importer set and runs the actual built private mint and settlement in a temporary
Main-unit control; it does not expose the mint through the ordinary test or downstream package boundary.

Two rules make a fixture worth having:

1. **It must fail for the named reason.** `rejectsWith` pins the expected diagnostic. A fixture that
   merely fails to compile proves nothing — a typo would satisfy it.
2. **The expectation must not be satisfiable by an unrelated error.** Splitting an expected diagnostic
   into separately-matched tokens is the common way to get this wrong: an unrelated in-scope error on
   the same source line can satisfy each token independently. Keep the expectation one contiguous
   phrase inside one diagnostic block. Distinct expectations require distinct error blocks; the matcher
   backtracks across candidate blocks and collapses whitespace and quote variants within each block.

Every registration takes `NonEmpty String` and states the rejection phrases observed from its fixture.
Fixtures compile with `-fno-diagnostics-show-caret`, so echoed source excerpts cannot supply an expectation.
The matcher separates error diagnostics before normalization; warning text, paths and preambles supply no
rejection evidence. A fixture whose arity or kind error precedes its intended question needs fully applied
types before its hidden-constructor or nominal-role diagnostic can hold the boundary. The source-definition and registration inventories enforce the same discipline across the complete fixture tree.

The fixture inventory compares every file with its unique registration and checks first-party import
modules and names against real library definitions under every declared source root. The definition
reader collects declaration binders, constructors, record labels, class members and foreign binders;
imports, exports, type references, patterns, comments and literals cannot supply a definition.
Unsupported forms fail explicitly. A private name remains eligible for a negative import probe because
it exists in the implementation even while its public facade withholds it.

A separate inventory pins the exact export tokens of every effective Main facade importing a
hidden or private implementation, plus the explicitly included locally sealed registry plan. Main's
bare reexports are resolved to their actual source homes under the same sealed-input policy. The
inventory contains 97 reviewed literal lists within the unchanged 104-module public surface. Missing,
duplicate, stale or changed pins fail, and every named library unit must declare private visibility.

The 57 handoff implementation modules have one compiled owner in `handoff-implementation-internal`.
Main's disjoint home roots prevent a second home-module copy. The private unit exposes 52 modules for
trusted component imports and retains five `other-modules`; Main reexports only the public 29, and the
core-test mixin selects only Protocol, Receiver, Relay, Internal and Rooted from the handoff family. The
19 additional Main imports remain absent from its consumer facade; the other 18 implementation origins
remain withheld from that selected test context. Rooted still refuses through the ordinary Main-only
consumer context, while its test-only route uses the existing production types.
`SourceGuard.mainImplementationOwners` and the effective-facade readers keep ownership distinct from
consumer visibility. Compiler controls consume the current core-test build-info arguments and compare
actual unit origins; source-file uniqueness alone is not a shared-type-identity proof. See
[testing](../engineering/testing.md#one-toolkit-for-reading-this-repositorys-own-sources).

## Tests that pin a defect

This is the failure mode the method is meant to remove, and the one that hides longest.

A test asserting the current value of an unsealed field cannot distinguish "this is the right value"
from "this is the value that happens to be there". If the held value is wrong, the assertion promotes
the defect to a contract, and every gate then agrees with it — which is indistinguishable, from the
outside, from the boundary holding.

The host-daemon launch carried exactly such a test: three assertions that its stdio disposition equalled
the one that closed the child's descriptors. It was green for as long as the defect existed.

Prefer an assertion that the lawful shape **does the lawful thing**. A child launched through a sealed
boundary can be observed to have an open standard input at EOF and both output streams reaching one
place; no unlawful disposition passes that test, so it fails when the boundary is missing instead of
certifying its absence.

## What this does not buy

Stating the limits is part of the contract, not a caveat appended to it.

- **It does not exclude an external actor.** Hidden constructors exclude construction by cooperating
  code in this repository. A same-privilege process outside it is unaffected, and
  [ownership_invariant.md](ownership_invariant.md) is explicit that no substrate supplies that
  exclusion.
- **It does not bind a caller who reaches past the boundary.** Sealing a module does not remove the
  underlying package from the build plan. Keeping a surface sealed is a drift-guard obligation, owned
  by the [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md),
  not a property the type system maintains on its own.
- **It does not make a runtime effect exactly-once.** § EE states the limit directly: no plan may claim
  compile-time exactly-once effects from phantom types alone. Ordinary Haskell values are not linear;
  "consumed" is an interpreter invariant enforced by a journal, and the type only prevents forging the
  token. The lifecycle cursor demonstrates the distinction: one protected CAS reserves each transition
  at most once, but its callback runs after unlock and is deliberately at-least-once. Recovery or a
  callback exception may redeliver the same durable phase; backend exactly-once behavior still requires
  its own journal/fence/idempotence contract.
- **It does not make an unsound design sound.** A closed sum over the wrong domain is still wrong.
  Totality guarantees every case is *considered*, not that the cases are the right ones.

## Current boundaries

A row whose fixture column reads "—" names a boundary with no compile-fail fixture: under § HH its claim is
unproven, and a runtime suite named beside the dash does not discharge it. A field count such as
"four-field `OpenFrame`" counts the length-framed fields of the canonical wire encoding, including its domain,
version, and variant frames, not the fields of the Haskell constructor.

| Boundary | Sealed value | Fixture |
|---|---|---|
| Host-tool resolution (§ K) | `AbsExe` — constructor hidden, admitted by `mkAbsExe`, inspected through the ordinary `absExePath` function | `RelabelAbsExe.hs`, `HostToolSpec` |
| Owned-object vocabulary (§ EE) | `ObjectIdentity`, `PayloadDigest`, `OriginRecord` — the kernel answers the identity, the digest is computed from the payload a run intends to install, and the record has no updatable field, so its binding cannot be replaced | `ForgeObjectIdentity.hs`, `ForgeOwnershipPayloadDigest.hs`, `ForgeOwnershipOriginRecord.hs`, `RebindOwnershipOriginRecord.hs` |
| The four clause tokens (§ EE) | `Entered`, `Recorded`, `Bound`, `Releasable` — each minted by a clause actually being held, each indexed nominally by the protected entry that authorized it and by the object it names, with the entry index the protected session's own rank-2 variable; the actual session is retained and each typed effect requires its live owning thread | `ForgeOwnershipEntered.hs`, `ForgeOwnershipRecorded.hs`, `ForgeOwnershipBound.hs`, `ForgeOwnershipReleasable.hs`, `CoerceOwnershipClauseSession.hs`, `CoerceOwnershipClauseObject.hs`, `EscapeOwnershipClauseEntry.hs`, `ImportOwnershipInternal.hs` |
| Readiness (§ CC) | `Ready`, `PollPolicy`, and `Micros` are public abstract types; the public `Probe` synonym exposes no `Probe` term constructor | `RawReadiness.hs` independently pins `PollPolicy`, `Micros`, and `Ready`; `RawProbe.hs` pins the unavailable public `Probe` term spelling |
| Capabilities and lifecycle state (§ EE) | `PreparedGate`, ownership receipts, `UnboundRunLease` and `BoundRunLease`. `PreparedGate`'s coordinates are typed one role each — plan digest, operation key, session, fence, attempt, journal version, and for a rooted package the catalog identity, frame, and supersession generation — so two adjacent coordinates of the same underlying type cannot be transposed between the producer and the canonical renderer | `ForgePreparedGate.hs`, `ForgeRunLease.hs` |
| The interrupted-transaction seam (§ NN) | The private `lifecycle-transaction-internal` unit exposes only `Session.Testing`'s coordinator DATA vocabulary, which mints no authority. `Lifecycle.Transaction` is hidden in that unit's `other-modules`; its distinct production copy is hidden in `handoff-implementation-internal`, which imports neither DATA unit. The rendered bytes are still the coordinator's own | Required controls: `ForgeTransactionPermitFromDescriptor.hs` for public hidden-package refusal and testing-unit DATA access; `ImportTransactionRunnerFromTestingUnit.hs` for testing-unit hidden-module refusal; `SessionSpec` stanza guard |
| Provider-wall admission and settlement (§ EE) | journal-derived `ProviderWallReservation`; nominal backend-produced `ProviderWallSettlementPermit`; journal-bound provider start completed only by a hidden owning adapter | `CallerFenceProviderWallReservation.hs`, `CrossPartitionProviderWallReservation.hs`, `ForgeProviderWallSettlementPermit.hs`, `RawObservationProviderWallSettlement.hs`, `ImportBudgetInternal.hs`, `ImportColimaSettlementInternal.hs`, `ForgePreparedProviderStart.hs`, `ImportProviderStartInternal.hs`, `CoerceProviderWallSettlementPermitRoles.hs`, `CoercePreparedProviderStartRoles.hs` |
| Storage-wall settlement | The private `StorageWallSettlementPermit` joins the exact prepared call, journal lineage, and live provider wall; the applied proof retains that wall epoch. Storage tokens come from the production provider sizing renderers. Raw storage observations cannot be constructed through the public budget facade | `RawStorageWallObservation.hs` |
| Exact direct-Colima ownership (§ EE/§ HH) | opaque `PreparedColimaWallCall`, backend-minted `ColimaWallObservation`, `LiveColimaWall`, `ColimaCleanupAuthority`, and journal-bound `PreparedColimaCleanupCall`; private resolver/backend/settlement constructors and mutation arguments on the `HostBootstrap.Ensure.Colima` facade. The owning driver and raw observation constructors are confined to the private `colima-ownership-internal` library; public mutations use the sealed facade | `CrossPlanColimaConsumer.hs`, `ForgeColimaAuthorities.hs`, `CoerceColimaAuthorityRoles.hs`, `ImportColimaOwnership.hs`, `ImportColimaObservation.hs`, `ImportColimaBackendRunner.hs`, `ImportColimaResolverOverride.hs`, `ImportColimaResolverTesting.hs`, `ImportColimaResolverInstall.hs`, `ImportColimaSettlementInternal.hs`, `OpenColimaOwnershipBackend.hs`, `OpenPreparedColimaMutationArgs.hs`, `ColimaAcquireCallAsCleanupGate.hs`, `WrongColimaCleanupPhase.hs` |
| Installed and broker identity (§ X) | `InstalledProjectIdentity`, `BrokerEpoch` | `EscapeInstalledProjectIdentity.hs`, `ForgeInstalledProjectIdentity.hs`, `CoerceInstalledProjectIdentity.hs`, `CoerceBrokerEpoch.hs` |
| Indexed project mode (§ EE/§ HH) | Private-constructor, three-role-nominal `ProjectModeLease projectId mode brokerGeneration`; empty Production/Harness type tags and a private runtime wire sum. Only the protected scope-specific transitions mint a lease; the generic mutation kernel is not public | `ForgeProjectModeLease.hs` imports the real constructor; `CoerceProjectModeLease.hs`, `CoerceHarnessModeRun.hs`, `OpenGenericProjectModeMutation.hs` |
| Indexed journal values (§ EE/§ HH) | Nominal scope and plan roles on `ProjectPermit`, `ClosingProjectPermit`, `ClosedProjectPermit`, `OperationSession` and `OperationAdvance`; the advance's result remains representational. These roles hold value non-coercibility, not runtime authentication of the generic producer's plan text | `CoerceProjectPermitScope.hs`, `CoerceProjectPermitPlan.hs`, `CoerceClosingProjectPermitScope.hs`, `CoerceClosingProjectPermitPlan.hs`, `CoerceClosedProjectPermitScope.hs`, `CoerceClosedProjectPermitPlan.hs`, `CoerceOperationSessionScope.hs`, `CoerceOperationSessionPlan.hs`, `CoerceOperationAdvanceScope.hs`, `CoerceOperationAdvancePlan.hs`; positive payload control in `CompileFailSpec` |
| Closed-session observation (§ EE/§ HH) | Abstract `VerifiedAllSessionsClosed scope planId` has both roles nominal. Held-value separation does not authenticate the raw-text producer's plan, scope or store | `CoerceVerifiedAllSessionsClosedScope.hs`, `CoerceVerifiedAllSessionsClosedPlan.hs`; abstract export pin in `SealedExportInventory`, with the dedicated constructor-forgery proof still owed |
| Indexed fence values (§ EE/§ HH) | Private-constructor `FenceEpoch scope planId` and `OldPermitsFenced scope planId` with both roles nominal. Their producers derive the coordinate and output indices from the actual held `ProjectPermit`; held-value coercion and cross-plan prepared-gate use refuse. Authentication of an admitted plan by the generic journal-permit producer remains separate | `ForgeFenceEpoch.hs`, `FenceEpochFromOtherPermit.hs`, `CrossFenceEpochPreparedSession.hs`, `CoerceFenceEpochScope.hs`, `CoerceFenceEpochPlan.hs`, `CoerceOldPermitsFencedScope.hs`, `CoerceOldPermitsFencedPlan.hs` |
| Observed intent origin (§ EE/§ HH) | Public absent-only `NoHistory` and a private released variant retaining observed store/key/physical version. Registration revalidates the same ordinary `Released` phase; it grants no old-key-to-new-key rollover or backend-history proof | `ForgeReleasedIntentOrigin.hs`, `SessionSpec` origin controls |
| Root authority (§ X) | `RootInvocationAuthority`, `RootScopeAuthority`; no public root or recorded-epoch opener | `ForgeCommandAuthority.hs`, `CrossRootScopeAuthority.hs`, `ForgeRootScopeAuthority.hs`, `OpenRootInvocationAuthority.hs`, `OpenRecordedBrokerEpoch.hs` |
| Command authority (§ X) | nominally indexed `CommandAuthority`; no generic producer in the safe authority facade | `ForgeCommandAuthority.hs`, `CrossScopeCommandAuthority.hs`, `CrossPlanCommandAuthority.hs`, `CrossFrameCommandAuthority.hs`, `OpenCommandReservation.hs` |
| Authority kernel package boundary (§ X) | `HostBootstrap.Authority.Kernel` and its narrow fixture seam share the Cabal-private `authority-internal` unit; the main library re-exports only the shared project-scope module | `ImportAuthorityKernel.hs`, `ImportAuthorityTesting.hs` |
| Plan-bound acquisition and frame cursor (§ W/§ EE) | hidden-constructor `AcquisitionJournal`; six-role nominal `LifecycleCursor`; existential current-phase recovery; only adjacent phase successors | `ForgeLifecycleCursor.hs`, `CoerceLifecycleCursorScope.hs`, `CrossPlanLifecycleCursorOpen.hs`, `CrossFrameLifecycleCursor.hs`, `CrossBrokerLifecycleCursor.hs`, `CrossVerbLifecycleCursor.hs`, `CrossPhaseLifecycleCursor.hs`, `SkipLifecycleCursorExecute.hs`, `AdvanceTerminalLifecycleCursor.hs` |
| Durable reverse-root intent substrate (§ W/§ X/§ Y) | module-private, three-role-nominal `ReverseRootIntent`; exactly Pending, Committed, and Terminal states for Down and for Destroy (six constructors); no public producer, projection, transition, repair, deletion, recovery, or test seam; ordinary snapshot, allocation, migration, Harness, profile-slot, and terminal-mutation funnels refuse an active or malformed intent at its stable key, while lower acquisition/cursor open and reopen remain deliberately non-authorizing | `OpenReverseRootIntent.hs`, `ProjectPlanSpec`, `SessionSpec` |
| Durable reverse descent (§ W/§ X/§ Y/§ HH) | Cabal-hidden, eight-role-nominal `ReverseDescent` has only private Prepared and Bound constructors. Prepared retains the exact entry/work/adapter/authority package; Bound retains canonical binding bytes plus its exact durable successor, never an offer or token. Planned-token replay may reproduce the same offer for transmission, while a separate strict hidden path reauthorizes and rehydrates exact Bound state without opening the token map. Neither constructor nor retained term enters the public library surface, and full Prepared bytes are bounded before publication | `OpenReverseDescentSubstrate.hs`, `OpenPreparedRootReverseDescentProducer.hs`, `ProjectPlanSpec` |
| Sealed semantic lifecycle completion (§ W/§ X/§ Y/§ HH) | Cabal-private lower `Handoff.Completion` owns exactly five exports: the four-role-nominal `LifecycleCompletion`, three fixed-unit acknowledged producers, and its proof-only fold. Cabal-private `Handoff.TerminalReport` accepts only an exact typed rooted Up session plus coordinator-produced canonical origin bytes and renders the completed report without a store, signer, process, Chain, or command import. `Command.LifecycleEntry` is its sole origin producer and adopts the lower completion fold inside validated receipt confirmation; Process retains the other fixed forward/reverse completion call sites. The root coordinator produces canonical forward and reverse terminal origins; storeless children return authenticated observations. Receiver imports none of them, and no testing seam exists | `ImportHandoffCompletion.hs`, `ImportHandoffTerminalReport.hs`, `HandoffLifecycleProducers.hs`, `HandoffSpec`, `ProjectPlanSpec` |
| Root-resident lifecycle acknowledgement substrate (§ W/§ X/§ Y/§ HH) | Hidden root-parent kernels retain exact binding, challenge, full grant, report, acknowledgement, and lawful Reported→Acknowledged→Adopted successors. Exact CAS losers converge, strict readback runs under the root broker guard, and fixed callbacks expose no store, durable row, disposition, or caller-selected result. No child-side persistence claim belongs to this boundary | [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) proof matrix |
| Keyless rooted transport (§ W/§ X/§ Y/§ HH) | The authenticated-handoff phase limits Relay to singleton outer fields, bounded sealed external requester-path construction, exact inner-byte preservation, strict structural request/response pairing, one outstanding request, intermediate path-suffix checks, and complete root-path equality. Only the originating typed operation verifies the signed response with the independently installed key. Received outer refusal code/detail and signed rooted refusals remain distinct uninterpreted bytes. A successful locally originated upstream refusal closes the retained edge before later reports, relay requests or Receiver announcements; a pre-send validation error leaves it open for notification. Structural boundary DATA uses a capturing root service and declared sentinel refusal, without claiming recursive processes or lifecycle success. After that structural validation the root link runs the rooted lifecycle service the recursive-lifecycle-command phase installs, whose shape is the link field's own, so the transport decides whether a request is well formed and never what it is answered with. Relay exposes no broker, store, catalog, retained session path, semantic replay/receipt decision, process owner, raw response, polymorphic result, or terminal callback, and reaches the fixed signer only through its own hidden recovery signing admission; it constructs no recursive child and claims no successful rooted process exchange | `ImportHandoffRelay.hs`, `HandoffSpec` source guards, [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) semantic/process proof matrix |
| Rooted terminal receipt (§ W/§ X/§ Y/§ HH) | Only the root writes Published/Received: it retains the exact admitted offer for the matching session, produces a terminal origin only after all exact frame work settles, publishes before signed `FrameComplete`, admits fixed semantic completion inside idempotent `ReceiptConfirm`, and only then returns signed `ReceiptRecorded`. A child receives no `ProtectedStore`, raw receipt key, receipt mutation helper, completion constructor, catalog, or signer | [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) proof matrix |
| Finalized forward-child projector (§ W/§ X/§ Y/§ HH) | Real-project construction installs exactly one scope-polymorphic projector; missing and duplicate installation refuse structurally. The hidden kernel canonically validates child configuration through the finalized codec and exposes only fixed projected plan inputs. No projector-derived bytes, root constructor, caller-polymorphic result, or runtime seam exists | `ImportProjectPlanConstructInternal.hs`, `OpenFinalizedForwardChildProjector.hs`, `CLISpec`, `ProjectPlanSpec` |
| Exact planned forward handoff (§ W/§ X/§ Y/§ HH) | Opaque `PlannedForwardHandoff` joins exact parent plan/current/context evidence to the unique immediate child edge, independently constructs the target plan and digest binding, and retains only inert binding input plus a sanitized route. It owns the lifecycle-context join alone and delegates every descriptor, context, configuration, and target-plan check to the shared immediate-target kernel. It exposes no live broker, token, selectable executable, `SelfRef`, store, cursor, process, or effect authority and has no runtime caller. The catalog-admitted forward package below supersedes it, and the [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owes its deletion | `OpenPlannedForwardHandoff.hs`, `ProjectPlanSpec`, [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) source guards |
| Shared immediate-target projection (§ W/§ X/§ Y/§ HH) | Cabal-hidden `withImmediateTargetKernel` is the one boundary that proves the unique immediate ancestry edge and jointly yields the projected descriptor, canonically validated child configuration, independently admitted target plan, digest binding, target current frame, exact derived child context, raw and stripped route, canonical payload, both digests, and invocation input. It introduces no type and retains no `ValidatedLifecycleContext`, canonical root, protected store, or invocation authority, which is why the exact single-edge package and the recursive catalog can share it without either borrowing the other's lifecycle evidence. Its only importers are those two hidden owners | `ImportProjectPlanProjectionInternal.hs`, `OpenImmediateTargetProjection.hs`, `ProjectPlanSpec` |
| Recursive rooted plan catalog (§ W/§ X/§ Y/§ HH) | Cabal-hidden, four-role-nominal `RootedPlanCatalog` is its own entry carrier: one base retaining the root's finalized specification, invocation authority, plan, current frame, and root-resident lifecycle context, plus one extension per admitted descent. Construction rechecks root residency, the supplied/retained/project frame join, the admitted context endpoint, and the authority's installed project and durable store identity before descending through the shared kernel; descent terminates at a frame with no declared edge and is bounded by the root topology's own frame count. Every entry is reachable only through rank-2 folds over the catalog, so no entry, evidence value, raw row, child-supplied plan, or nested lifecycle-context route exists. The value grants no journal, cursor, session, grant, signing, process, or protected-store operation; the root lifecycle entry consumes it to select exact frame sessions and dispatch | `ImportLifecycleRootedPlan.hs`, `OpenRootedPlanCatalog.hs`, `ProjectPlanSpec` |
| Catalog-admitted forward package (§ W/§ X/§ Y/§ HH) | Cabal-hidden, eight-role-nominal `CatalogForwardHandoff` exists only for an edge the recursive catalog already admitted. One rank-2 catalog fold selects by exact parent and child frame and refuses a missing, duplicated, or sibling child; it then rechecks the entry against the parent level's own retained plan, so a parent frame that is not that level's current frame, a descent the parent plan does not declare with exactly the retained raw route, or projected node keys that are not the parent plan's own all refuse before the fold. The package rechecks the admitted child against the evidence the entry retains — target-plan current frame, validated-configuration endpoint, rendered plan digest against the binding's, and configuration/payload digests against each other and against the canonical payload's own hash — and holds both routes to exactly one lift layer. It retains no lifecycle context, parent plan, or specification index, exposes only the stripped route, binding input, and canonical payload under a fixed unit result, and has no process or command call site | `OpenCatalogForwardHandoff.hs`, `ImportProjectPlanHandoffInternal.hs`, `ProjectPlanSpec`, `CLISpec` |
| Protocol-safe lifecycle process route (§ K/§ W/§ X/§ HH) | Cabal-hidden, seven-role-nominal `LifecycleProcessRoute` is derived from a catalog forward package or a recovery package and its plan-owned lift route, never assembled, and points only at the child a frame launches rather than at that frame's own session: the parent and child frames are the binding input's own, the phase must be the one that edge belongs to, and the lift must be exactly one plan-owned layer. One argument vector exists per provider — Docker interactive at `/`, Incus, Lima, and WSL noninteractive at `/` with noninteractive sudo where the guest's default user is not root — the interactivity that separates them is a two-case `ChannelInteractivity` carried by the route and by every named result that reaches it rather than a boolean in a tuple position, and the child's command is the fixed coordinate-free `--hostbootstrap-lifecycle-child` entry marker; the authenticated Offer is the sole source of its verb. The closed grammar refuses `ConfigDelivery`, container extra arguments, a container outliving its exchange, a non-absolute or delimiter-bearing path, and any derived name reading as an option, a separator, or a descriptor request, so detach, TTY, attach, standard-input, entrypoint, working-directory, and signal overrides are unrepresentable rather than filtered; what the grammar admits leaves it as `ValidatedArgument` or `ValidatedPath`, so a renderer cannot be handed text that was never admitted. The one startup step with no other owner sits beside it rather than on it: a frame's own opening admits the nested arm of that frame's `RecursiveHandoffRuntime` — a root arm speaks for no authenticated frame — builds the four-field `OpenFrame` from a fresh nonce alone, and verifies the signed answer against the installed key and those exact bytes, admitting only an `Opened` and yielding that request and that response with no decoded coordinate. No post-open request builder exists here at all: the storeless frame executor already owns the root-selected path, session, stage, ordinal, and predecessor and the closed post-open families. It names no process, descriptor, handle, store, signer, or executor and spawns nothing | `ImportHandoffProcessRoute.hs`, `RenderLifecycleProcessRouteArgv.hs`, `ProjectPlanSpec` |
| Digest-proven specification reindex (§ Q/§ BB/§ HH) | `ProjectCodec scope specDigest cfg` and `FinalizedServiceRegistry scope specDigest (cfg scope)` each keep a nominal specification index, so a carrier admitted under a durably recovered index and one finalized in this invocation are distinct types even when their digests are equal. Each representation lives in its own Cabal-hidden owner whose only importer is the facade that re-exports it abstractly, and each owner holds exactly one reindex kernel. A kernel consumes the digest-equality token, compares it against the digest the carrier itself retains — the registry retains the exact digest its finalization stamped, so an empty registry is checked too — and preserves every retained term: label, schema, digest, decoders, renderers, and the registry's identities, projections, declared effect rows, handlers, and role codec terms. Neither kernel reaches a public facade, mints a token, or admits a caller-selected index | `ImportConfigClassInternal.hs`, `ImportServiceInternal.hs`, `OpenProjectCodecReindex.hs`, `OpenFinalizedServiceRegistryReindex.hs`, `CoerceProjectCodecSpec.hs`, `CoerceFinalizedServiceRegistrySpec.hs`, `SpecIndexSpec` |
| Bracketed recursive process (§ HH) | the owner accepts only catalog-admitted planned or recovery input, constructs process/channels internally, fixes cwd and argv, isolates descriptors, and completes only after rooted semantic completion and receipt. It spawns exactly one sanitized `LifecycleProcessRoute` at the absolute path its host tool resolves to, into a new process group with private stdin/stdout pipes and inherited stderr; no caller supplies a callback, deadline, grace value, process shape, or channel, and an already opened route launches no second child. One bracket owns the descriptors, the relay lifetime, the direction's fixed completion kernel, and the reap: on a POSIX host group TERM, fixed grace, group KILL if still present, unconditional wait, then the pipes; on a Windows host both the stop and the kill step terminate only the launched child, so its descendants are not reaped (see [Current Status](#current-status)). Its constants bound the launch and the grace only; the relay bounds the frames a peer owes immediately and leaves the admitted effect's own wait alone, so no blanket lifecycle wall-clock deadline exists. EOF, exit zero, diagnostics, and channel closure are not completion. Catchable host exits terminate and reap the host-side group on POSIX and the direct child on Windows; uncatchable parent death promises only pipe EOF/kernel cleanup and no guest-descendant reap | [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) proof matrix |
| Exact validated lifecycle context (§ W/§ X/§ EE) | opaque five-role-nominal `ValidatedLifecycleContext` retains canonical root, the coordinator's already-open protected store, and root-or-nested parent-plan `CurrentFrame`, `ProjectFrame`, and `ValidatedContext`. It is root-process-resident and has no child-process eliminator; rank-2 `RootedPlanCatalog` selection structurally binds a target plan/config/current frame without a second evidence type or store authority | `ForgeValidatedLifecycleContext.hs`, `CoerceValidatedLifecycleContextRoles.hs`, `CrossValidatedLifecycleContextIndices.hs`, `EscapeValidatedLifecycleContextFrame.hs`, `ValidatedLifecycleContextAsAuthority.hs`, `ImportLifecycleContextInternal.hs` |
| Closed rooted lifecycle request codec (§ X/§ Y/§ HH) | One Cabal-private, non-indexed, hidden-constructor six-case sum has checked constructors, strict canonical decode/render, and one total fold. Four-field `OpenFrame` contains only a nonce; the nine-/ten-field post-open forms bound their nested path, tokens, ordinal, nonce, predecessor digest, and optional body. The public response verifier decodes the exact request before response parsing, pairing, signature work or callback entry. The exact-source gate proves single ownership and the absence of facade exposure, authority/storage imports, testing companions, and semantic/process/durable importers; only the neutral Receiver-internal path fold serves Relay transport, and it assigns no lifecycle semantics | `ImportHandoffRooted.hs`, `HandoffSpec` source guards and public-verifier malformed-request DATA controls |
| Closed rooted lifecycle response codec and authentication (§ X/§ Y/§ HH) | The neutral codec adds one Cabal-private, non-indexed, hidden-constructor seven-case sum as descriptive signed data, not authority. Exact nine-field `Opened` and eleven-field post-open forms have seven checked unsigned builders, one signature-attaching decoder, strict canonical decode/render, one total fold, exact request-family pairing, and 7 MiB/6 MiB total/body bounds. `Prepared` nests node/dependencies/operation-gate/projected-gates; `FrameComplete` is structurally opaque; `ReceiptRecorded` repeats the matching predecessor digest; rooted `Refused` is post-open only. The no-new-type public facade exposes only the abstract value, renderer, fixed live-broker signer over domain + installed-key digest + exact request + canonical unsigned response, and installed-key fixed CPS verifier. That verifier takes the installed key, exact request and signed wire before its continuation, with no separate project-identity argument. Exact pairing precedes signature verification; the facade validates a canonical `FrameComplete` report before signing and after signature verification before callback entry. Its sole transport caller is Relay's originating typed operation, after the neutral Receiver-internal pair fold; no caller-supplied signature placeholder, generic signer, second capability, store, semantic successor, or semantic/process/durable importer belongs to these boundaries. The recursive-lifecycle-command phase alone assigns typed body, successor, settlement, and replay semantics | `ImportHandoffRooted.hs`, `HandoffSpec` source/ownership guards |
| Rooted plan catalog and frame executor (§ W/§ X/§ Y/§ HH) | Only the root can construct `RootedPlanCatalog`, select a catalog node and projected operation set, mutate a frame journal, or sign a rooted response. Four-field `OpenFrame` carries no path or session coordinate: its sealed external envelope is the sole ancestry and obeys the same one-to-256-component, 4,096-byte-per-component grammar as the inner post-open path; attachment failure is outer refusal. Only verified exact nine-field `Opened` discloses the admitted canonical path plus root-issued session/stage/next ordinal; it contains no digest of itself. Once the complete signed `Opened` is available, its derived digest seeds the first predecessor for the next request. Eleven-field post-open responses echo request path/session/nonce, supply successor stage/ordinal, and stay inside the exact family. Post-open inner path must equal envelope and session path before mutation. A `FrameExecutor` is storeless, exists only after that verification, and can reify prepared gates only after exact local comparison of the four nested node/dependencies/operation-gate/projected-gates packages — packages it reads out of a verified `Prepared` answer rather than accepts beside one, so a `Descend` or a signed `Refused` cannot reach the same branch. The Cabal-private owner participates in the catalog-selected authenticated process exchange. Closed request/response sums, lineage/catalog/path/nonce replay identity, ordinals/nonces/predecessor digests, and strict replay prevent accidental route/key substitution; they do not claim identity against a malicious launching parent | recursive lifecycle compile-fail/source-guard matrix |
| Rooted recovery package (§ W/§ X/§ Y/§ HH) | Neutral `RecoveryChildPackage` canonically frames child-config plus adapter bytes but authenticates nothing by possession. `RootedPayloadBinding` commits separately to the complete package and child-config field. `withVerifiedRecoveryChildPackage` requires the exact `VerifiedHandoff`, rerenders and reverifies the supplied signed data, decodes only the authenticated payload, and recomputes both digests before exposing fields. The [authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md) owns that boundary and its generic package-aware receiver carrier, which composes no package of its own. The [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) alone constructs the catalog-selected package, admits its complete config/digest, and routes its exact Offer to the installed root signer; its reverse transport takes no payload argument, so an adapter alone is unrepresentable there | handoff/recovery negative matrix |
| Plan, descent, reverse (§ W/§ Y) | `StepPlan`, `StepExecution`, plan/config-indexed `PlannedStepObservation`, `TeardownForest` | `ForgeStepExecution.hs`, `CoercePlannedStepObservationRoles.hs`, `ForgeTeardownForest.hs` |
| Provider runtime dependency production (§ CC/§ EE/§ HH) | Only an exact prepared provider Ready call settled to its backend-indexed `Running` successor can publish the pending provider-domain package. Plan/frame/resource/origin/generation come from that exact execution and successor; separate commitments hash the complete still-pending producer gate and the action-local Ready call/observation. The canonical package cannot contain the captured strong backend or managed handle, while the separate invocation-local live registry accepts only the fixed fresh-readiness request. Exact retry converges, canonical drift refuses, and every new carrier begins empty | `ProviderBackendSpec`, `LifecycleDependencySpec`, `ImportLifecycleDependencyInternal.hs` |
| Exact carried ownership opening (§ EE/§ HH) | The existing private carried resource retains the already-validated ownership operation independently of optional local settlement bytes, never a receipt or managed witness. An authenticated dependency package may seed the exact resource/generation/operation without gaining settlement publication authority. Only `Reconcile` can combine key/generation/version/operation into a freshly rebound generic managed handle and matching receipt under a rank-2 continuation, and only for the current node or its exact plan dependency prefix. Missing ownership, unrelated keys, duplicate membership, empty operation, and a fresh carrier refuse before the continuation | `ReconcileSpec`, `ChainSpec`, `ResourceRecordSpec`, `RecursiveLifecycleSpec` |
| Fresh provider dependency recovery (§ CC/§ EE/§ HH) | A fixed successor must join the sole exact provider package, a plan-admitted provider resource, carried ownership evidence, reconstructed backend origin, unexpired route, and a live backend response. The request/response canonically bind the complete package commitment plus one bounded nonce; the service consumes the nonce once and returns only that commitment, nonce, and freshly observed generation. Only their full agreement constructs a backend-indexed managed provider and exposes `RunningProviderDependency` under a rank-2 continuation; neither canonical bytes nor reachability alone can mint it | `ProviderBackendSpec`, `LifecycleDependencySpec`, `EscapeFreshRunningProviderDependency.hs` |
| Cluster runtime dependency production and recovery (§ CC/§ EE/§ HH) | Only an applied exact cordon plus a freshly reprobed settled readiness witness can register the cluster-domain package and separate live service. Canonical bytes bind plan, scope, cluster resource/frame, closed backend origin, managed generation, pending producer gate, ready settlement, route, and expiry but contain none of the captured backend, cordon, readiness, probe, receipt, or writer. The opener requires the sole exact package and every successor-visible coordinate, consumes a nonce-bound fresh service observation, and asks `Cluster.Reconcile` to settle another fresh observation inside the continuation; package presence or a carried ready version alone yields nothing | `ClusterBackendSpec`, `LifecycleDependencySpec`, `ImportLifecycleDependencyInternal.hs` |
| Exact current-frame Chain (§ W/§ X/§ EE) | one `ProjectPlan` plus matching execute-phase `CommandAuthority` and `LifecycleCursor`; nominal observation flow | `CrossAuthorityChain.hs`, `CrossCursorChain.hs`, `CoercePlannedStepObservationRoles.hs` |
| Production command plan continuity (§ W/§ X/§ Y) | one retained or fixed-identity reconstructed `ProjectPlan` across render/persist, the hidden fixed root-Up entry, lower Chain, and current-frame reverse work; only that entry derives journal/cursor/authority and no plan-only alternate producer exists | `CLISpec`, `AuthoritySpec`, `ChainSpec`, `TeardownSpec` |
| Exact current-frame reverse projection (§ W/§ Y) | nominal `TeardownPlan scope planId frame verb`, produced only from the matching `ProjectPlan` and `CurrentFrame`; projection-only opening retains `frame` through forest/progress/authorization/work/completion/`SubtreeSettled` | `CrossPlanCurrentFrameTeardown.hs`, `CrossFrameTeardownPlan.hs`, `CoerceTeardownPlanFrame.hs`, `CrossFrameTeardownPipeline.hs`, `CoerceTeardownFrameRoles.hs`, `CallerFrameNameTeardown.hs`, `DuplicateCurrentFrameTeardown.hs`, `OpenTeardownForestWithCurrentFrame.hs`, `ForgeTeardownPlan.hs`, `ForgeInitialTeardownForest.hs`, `ForgeTeardownForest.hs` |
| Canonical reverse verb (§ X/§ Y) | the same nominal `ProjectVerb verb` admitted by the command boundary is retained through teardown plan, forest, work, completion, recursive argv, and cluster action selection; no local teardown-verb universe or caller text exists | `CoerceProjectVerb.hs`, `CrossVerbTeardownWork.hs`, `ProjectUpCannotVerifyDestroy.hs`, `CallerTextAsProjectVerb.hs` |
| Recursive teardown work classification (§ X/§ Y) | hidden-constructor nominal `TeardownWork`, `LocalWork`, and existential-child `DescentWork`; only local work exposes execution, descent exposes only the exact immediate edge, and the driver has no generic point-effect callback | `ForgeTeardownWork.hs`, `LocalWorkAsDescentWork.hs`, `DescentWorkAsLocalRunner.hs`, `CrossFrameLocalWork.hs`, `CrossFrameDescentWork.hs`, `EscapeDescentChildFrame.hs`, `CoerceTeardownWorkRoles.hs`, `OpenTeardownWorkAgainstForeignForest.hs`, `GenericPointTeardownDriver.hs`, `ImportFormerTeardownCursor.hs`, `ImportDirectTeardownAdvance.hs` |
| Frame-bound subtree settlement and root destroy (§ X/§ Y) | nominal hidden-constructor `SubtreeSettled scope planId frame verb` retains the exact ordered terminal observations; descent accepts only its existential child's matching proof; unframed `DestroySettled scope planId` requires the exact plan/current-frame package and unique topology root | `ForgeSubtreeSettlement.hs`, `CoerceSubtreeSettlementRoles.hs`, `CrossSubtreeDescentSettlement.hs`, `CrossFrameTeardownPipeline.hs`, `ProjectUpCannotVerifyDestroy.hs`, `DownCannotVerifyDestroy.hs`, `SubtreeAsDestroySettled.hs`, `SubtreeAsDestroyClosure.hs`, `FramedDestroySettled.hs`, `LegacyRootDestroyVerifier.hs`, `ImportDirectTeardownAdvance.hs` |
| Process launch (§ HH) | `DetachedLaunch`, `DetachedChild`, `DetachedWorkingDirectory`, `DetachedOutputSink` | `ForgeDetachedLaunch.hs`, `RelabelDetachedLaunch.hs` |
| Authenticated recursive teardown entry (§ X/§ Y) | the exact child-entry wire consumed only with the plan-bound `DescentWork` edge; the root reverse-descent kernel and its bound/prepared descent types are unexported, and a caller cannot select the descent subtree | `OpenPreparedRootReverseDescentProducer.hs`, `OpenReverseDescentSubstrate.hs`, `CallerSelectedDescentSubtree.hs` |

The direct-Colima row is a source boundary owned by the
[cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md). Its Cabal-private resolver
testing seam exposes descriptive views and a non-nestable, thread-local, bracket-cleared fixture execution
override. Every adapter discovery and revalidation still runs strict fixture-root parsing and opaque resolver
settlement; the seam exports no trusted-toolchain/backend-result constructor and is absent from the public
library surface, so downstream code cannot use it to mint any value in the sealed column. No production
lifecycle module and no demo module consumes `HostBootstrap.Ensure.Colima`, and no phase schedules one; the CLI
reaches only the backend runner's shipped command entry. [Current Status](#current-status) records both this and
the exposed ownership module.

The exact Production command retains or reconstructs one plan identity and has no second command-authority,
forward-interpreter, descriptor, or reverse-plan entry. That absence does not make pure reverse work into
authority: `down`/`destroy` exact authorization remains part of the recursive boundary, and authenticated nested
lifecycle entry receives only storeless frame-execution authority.

The plan projection and work classification are exact: one plan plus its admitted current
frame produces the four-index `TeardownPlan`, while the opener accepts that projection alone. The forest,
authorization branches, hidden local/descent work, every successor and completion, and `SubtreeSettled`
retain the same nominal opening frame. `DestroySettled` is unframed and root-only. Only `LocalWork` exposes the retained reverse callback;
existential-child `DescentWork` exposes only the exact immediate topology edge, and branch-specific attempts
retain their originating forest; only the exact child subtree proof advances descent. Authenticated child entry consumes this boundary and is owned by
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
and its wire by [the authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md).
Phase status is tracked in [the development plan](../../DEVELOPMENT_PLAN/README.md); this page does not
duplicate it.

## The teardown descent boundary

This boundary starts from the `TeardownPlan scope planId frame verb` and closed
`TeardownWork` classification; it does not derive or accept another `CurrentFrame`. That existing index
reaches every forest and work state. Entry authenticates the exact `DescentWork`
parent/child edge and binds settlement to the resulting child completion.

A recursive verb reaches two states that look alike and are not. An **operator** types
`project destroy` at the topology root. A **parent frame** invokes the same verb inside its child during
a child-first unwind. One command class asked to mean both is a convention: it either admits the nested
form to an operator, or refuses the descent its own architecture requires.

The two states therefore get two types. The operator entry validates at the root and nowhere else. The
descent entry is admitted only by verifying the recovery wire its parent minted from the forest's own
authorization point — so its discriminator is an authenticated value on a private channel, not a flag,
an environment variable, or an `argv` position. There is no constructor for it without that wire, which the recovery-package, frame-executor, and reverse-entry compile-fail boundaries pin.

Alongside it, whether an offered node belongs to this frame is already a closed sum with a total eliminator,
not a comparison of frame names. The local reverse runner accepts only `LocalWork`; `DescentWork` exposes
only the exact immediate parent/child edge, and the driver itself accepts separate branch handlers. The
existing nominal `frame` phantom prevents mixing forests, successors, work, or settlement from different
openings; `CrossFrameTeardownPipeline.hs`, `CoerceTeardownFrameRoles.hs`, and the work-specific fixtures pin
that foundation.

The reverse driver verifies the complete recovery package and retains its exact forest authorization.
Only the matching child subtree completion advances the parent descent; private constructors and nominal
frame roles prevent callers from manufacturing that join.

## The process-launch boundary

`HostBootstrap.Detached` is the worked example of this page applied to a boundary that had none.

A child that outlives its launcher has exactly one lawful stdio disposition, descriptor-inheritance
setting, session, and console detachment, so none of those is a parameter. The working directory and the
environment are parameters of `detachedLaunch`, constrained rather than fixed: the working directory is an
absolute `DetachedWorkingDirectory`, and the environment is the child's complete environment, because a
detached child never inherits the launcher's. `DetachedLaunch`
hides its record constructor **and every field accessor** — the second half matters, because an exported
accessor still admits record update, which would let a caller re-point a launch it was handed.
`withDetachedChild` is a rank-2 bracket over the *launch*, not the child's lifetime: on exit the child is
still running and only the launcher's own handles have been released, so the acquire is total (it either
succeeds or returns a typed `DetachedLaunchError` having created no child) while the body's exceptions
propagate unchanged.

The lawful disposition is `UseHandle` throughout. Standard input is the host's null device, so the child
sees an open descriptor already at EOF; both output streams share one handle, so the child's own output is
retained where the launcher can quote it and a startup failure names its cause (§ CC) instead of
collapsing to "the process is gone".

It closed on a live run, not only on its static gate: the Apple Silicon lane had failed its whole matrix
against this exact defect, and against the sealed boundary the same matrix passes, with the daemon
reaching readiness on every bring-up and the browser case asserting real daemon-computed work. That is
the strongest available evidence that the sealed shape is the *lawful* one and not merely a different
one. The dated runs and their case totals belong to the
[Apple Silicon substrate acceptance phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md).

Its gate is the shape this page argues for. `DetachedSpec` launches a real child — this test executable
re-invoked through a probe argv — and observes that the child read its standard input to EOF, that both
its output streams reached the retained sink, and that it kept writing after the bracket returned. No
unlawful disposition passes that: `NoStream` closes the descriptor so the read raises, `Inherit` sends the
output to the test runner instead of the sink, and `CreatePipe` does not typecheck because the disposition
is not a parameter. A textual drift check additionally proves that no production module outside the
boundary so much as names `NoStream`.

The generic provider-start result, projection capability and fresh-managed-phase capability share
a declaration home in the private provider-start-internal leaf. That library depends only on base.
The public lifecycle imports those same types without exposing their module or constructors;
closed owning bridges and generic lifecycle code can share them without a dependency on the
public authority implementation.

The plan-independent Colima wall, owned-backend, expected-wall and native settlement observations
share one declaration home in the private HostBootstrap.Ensure.Colima.Observation module.
The public Colima facade reexports only its opaque wall-observation type. The owning adapter and
hidden settlement bridge import the same records; the private data module imports no public
authority implementation. LiveColimaWall still requires the exact plan, namespace and invocation
joins and both generic provider settlements.

The Colima command module exposes an opaque `ColimaProfile` from the same validator used for
ownership keys. Profile-targeting commands require that value; public code cannot forge its
constructor, as pinned by `ImportColimaCommand.hs`. Context-targeting commands require an opaque
`DockerContextName` derived from that profile; `ForgeDockerContext.hs` pins its hidden constructor.
Context listing admission and the settled wall projection derive the same context name from a validated
profile. An opaque `ColimaStartArguments` retains the validated profile and rejects a different or
repeated profile flag; ownership checks that it matches its own profile before entering the transaction.
`ForgeColimaStartArguments.hs` pins the hidden constructor.

The closed Colima settlement producer lives in the private colima-ownership-internal library.
It maps native applied/exact results to the matching provider-start result and wall epoch, and
supplies the private projection capability. The public adapter's unexported continuation uses
that capability to join the exact prepared journal pair, wall permit and provider-start completion.
Only a successful pair reaches LiveColimaWall; the public interface retains the same sealed values.

The private native resolver fixture entry retains the actual opaque resolver result produced by
its existing kernel walk and settlement. Descriptive views are pure projections of that same result.
Ready toolchain and missing-Colima Brew values remain private; no authority constructor or alternate
production resolver is exposed. These fixtures confirm native observation and static joins, while
the public Apple execution chain remains a separate live confirmation.

The owned static settlement cases apply the actual public `settleColimaWallCall` to private raw
observations carrying the native fixture's actual opaque toolchain result. State root, namespace
key, origin path, isolated Docker config, bound owner and exact journal invocation are checked
before live authority reaches the continuation. Hidden constructors and nominal roles remain
covered by the named compile-fail fixtures. Source guards pin the unchanged managed handle and
receipt flow; native fixture capability is declared through CoverageManifest without a fabricated
ready result on unsupported hosts.

The opaque prepared Colima cleanup call completes its retained Running-to-Destroyed transition
at the original managed resource generation whenever conditional release returns success, including
exact Released replay. Its result pairs that sealed phase advance with any post-call toolchain
diagnostic; a later standing failure does not withhold an already committed completion. A release
refusal completes nothing and retains its own typed error. Cleanup discovery explicitly requires an
existing Colima installation: trusted missing-tool evidence is a retryable failure, while acquisition
alone may install. A live Docker route revalidates its retained toolchain and never discovers or
installs. Pure decisions and actual native resolver-fixture results validate these choices; public
Apple cleanup execution remains live acceptance.
